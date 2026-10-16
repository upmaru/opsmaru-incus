defmodule Opsmaru.Incus.Transport do
  @moduledoc false
  alias Opsmaru.Incus.{Connection, Error, RequestContext, WorkScope}

  @doc false
  def request_headers(%Connection{require_authenticated: true}, headers),
    do: [{"x-incus-authenticated", "true"} | headers]

  def request_headers(%Connection{require_authenticated: false}, headers), do: headers

  # One passive connection per request. No pool/global remote/reconnect/retry.
  def request(connection, method, path, headers, body) do
    bounded(
      connection.timeout,
      method,
      fn ->
        do_request(connection, method, path, headers, body)
      end,
      connection.request_context
    )
  end

  @doc false
  def bounded(timeout, method, fun, context \\ nil) do
    case RequestContext.check(context) do
      :ok -> bounded_active(timeout, method, fun, context)
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp bounded_active(timeout, method, fun, context) do
    owner = self()
    ref = make_ref()
    deadline = RequestContext.deadline(context, now() + timeout)
    scope = WorkScope.current()

    {worker, monitor} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> guard(owner, worker, deadline, context) end)

        receive do
          {^ref, :start} ->
            WorkScope.bind(scope)

            result =
              try do
                fun.()
              rescue
                _ -> failed(method, :request)
              catch
                _, _ -> failed(method, :request)
              end

            send(owner, {ref, result})
        end
      end)

    if WorkScope.register(scope, worker) == :ok,
      do: send(worker, {ref, :start}),
      else: Process.exit(worker, :kill)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _} ->
        reason =
          if RequestContext.status(context) == :canceled,
            do: :canceled,
            else: if(now() >= deadline, do: :deadline, else: :request)

        failed(method, reason)
    after
      remaining(deadline) ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _} -> :ok
        after
          100 -> Process.demonitor(monitor, [:flush])
        end

        failed(method, :deadline)
    end
  end

  # Independent of both the caller's timeout and callback exit trapping.
  defp guard(owner, worker, deadline, context) do
    owner_monitor = Process.monitor(owner)
    worker_monitor = Process.monitor(worker)

    guard_until(owner_monitor, worker_monitor, worker, deadline, context)
  end

  defp guard_until(owner_monitor, worker_monitor, worker, deadline, context) do
    if RequestContext.status(context) != :active or remaining(deadline) == 0 do
      Process.exit(worker, :kill)
    else
      receive do
        {:DOWN, ^owner_monitor, :process, _, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_monitor, :process, _, _} -> :ok
      after
        tick(context, remaining(deadline)) ->
          guard_until(owner_monitor, worker_monitor, worker, deadline, context)
      end
    end
  end

  @doc false
  def watch_owner(owner, context \\ nil) do
    worker = self()

    spawn(fn ->
      owner_monitor = Process.monitor(owner)
      worker_monitor = Process.monitor(worker)

      watch_until(owner_monitor, worker_monitor, worker, context)
    end)
  end

  defp watch_until(owner_monitor, worker_monitor, worker, context) do
    if RequestContext.status(context) != :active do
      Process.exit(worker, :kill)
    else
      receive do
        {:DOWN, ^worker_monitor, :process, _, _} ->
          :ok

        {:DOWN, ^owner_monitor, :process, _, _} ->
          # Allow normal OTP termination, but never depend on the actor reading
          # its mailbox while negotiation or a socket write is blocked.
          receive do
            {:DOWN, ^worker_monitor, :process, _, _} -> :ok
          after
            100 -> Process.exit(worker, :kill)
          end
      after
        tick(context, :infinity) -> watch_until(owner_monitor, worker_monitor, worker, context)
      end
    end
  end

  defp tick(nil, timeout), do: timeout
  defp tick(_, :infinity), do: 20
  defp tick(_, timeout), do: min(timeout, 20)

  defp do_request(connection, method, path, headers, body) do
    deadline = RequestContext.deadline(connection.request_context, now() + connection.timeout)

    case open(connection, deadline) do
      {:ok, socket} ->
        try do
          case Mint.HTTP.request(socket, method, path, request_headers(connection, headers), body) do
            {:ok, socket, ref} ->
              receive_response(socket, ref, deadline, connection.max_response_bytes, %{
                status: nil,
                headers: %{},
                raw_headers: nil,
                trailers: [],
                header_bytes: 0,
                body: [],
                bytes: 0
              })

            {:error, _, _} ->
              failed(method, :request)
          end
        rescue
          _ -> failed(method, :request)
        after
          Mint.HTTP.close(socket)
        end

      {:error, _} ->
        {:error, %Error{kind: :connection}}
    end
  end

  @doc false
  def open(%Connection{transport: :unix, address: path}, deadline) do
    Mint.HTTP.connect(:http, {:local, path}, 0,
      hostname: "unix.socket",
      protocols: [:http1],
      mode: :passive,
      log: false,
      max_header_list_size: 65_536,
      transport_opts: [
        timeout: remaining(deadline),
        send_timeout: remaining(deadline),
        send_timeout_close: true
      ]
    )
  rescue
    _ -> {:error, :connection}
  end

  def open(%Connection{transport: :https, address: uri} = connection, deadline) do
    Mint.HTTP.connect(:https, uri.host, uri.port,
      protocols: [:http1],
      mode: :passive,
      log: false,
      max_header_list_size: 65_536,
      transport_opts:
        Connection.tls_options(connection) ++
          [
            timeout: remaining(deadline),
            send_timeout: remaining(deadline),
            send_timeout_close: true
          ]
    )
  rescue
    _ -> {:error, :connection}
  end

  defp receive_response(socket, ref, deadline, maximum, acc) do
    if remaining(deadline) == 0 do
      {:error, :deadline}
    else
      case Mint.HTTP.recv(socket, 0, remaining(deadline)) do
        {:ok, socket, responses} ->
          case collect(responses, ref, maximum, acc) do
            {:done, acc} -> {:ok, %{acc | body: IO.iodata_to_binary(Enum.reverse(acc.body))}}
            {:more, acc} -> receive_response(socket, ref, deadline, maximum, acc)
            {:error, reason} -> {:error, reason}
          end

        # recv uses the absolute remaining budget; its timeout is a local deadline.
        {:error, _, %Mint.TransportError{reason: :timeout}, _} ->
          {:error, :deadline}

        {:error, _, _, _} ->
          {:error, :response}
      end
    end
  end

  defp collect([], _, _, acc), do: {:more, acc}

  defp collect([{:status, ref, status} | rest], ref, maximum, acc),
    do: collect(rest, ref, maximum, %{acc | status: status})

  defp collect([{:headers, ref, headers} | rest], ref, maximum, acc) do
    bytes =
      acc.header_bytes +
        Enum.sum(
          Enum.map(headers, fn {name, value} -> byte_size(name) + byte_size(value) + 4 end)
        )

    if bytes <= 65_536 do
      acc =
        if is_nil(acc.raw_headers),
          do: %{acc | raw_headers: headers, headers: Map.new(Enum.reverse(headers))},
          else: %{acc | trailers: acc.trailers ++ headers}

      collect(rest, ref, maximum, %{
        acc
        | header_bytes: bytes
      })
    else
      {:error, :response_limit}
    end
  end

  defp collect([{:data, ref, data} | rest], ref, maximum, acc) do
    if acc.bytes + byte_size(data) <= maximum do
      collect(rest, ref, maximum, %{
        acc
        | body: [data | acc.body],
          bytes: acc.bytes + byte_size(data)
      })
    else
      {:error, :response_limit}
    end
  end

  defp collect([{:done, ref} | _], ref, _, acc), do: {:done, acc}
  defp collect(_, _, _, _), do: {:error, :invalid_response}

  defp failed(method, kind),
    do: {:error, %Error{kind: if(method in ["GET", "HEAD"], do: kind, else: :uncertain)}}

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now())
end
