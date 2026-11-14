defmodule Opsmaru.Incus.Transport do
  @moduledoc false
  alias Opsmaru.Incus.{Connection, ConnectionPool, Error, RequestContext, WorkScope}
  alias Opsmaru.Incus.ConnectionPool.{Binding, TLS}
  @compile {:no_warn_undefined, ConnectionPool}
  @compile {:no_warn_undefined, Binding}

  @doc false
  def request_headers(%Connection{require_authenticated: true}, headers),
    do: [{"x-incus-authenticated", "true"} | headers]

  def request_headers(%Connection{require_authenticated: false}, headers), do: headers

  def request(connection, method, path, headers, body) do
    deadline = RequestContext.deadline(connection.request_context, now() + connection.timeout)

    bounded(
      connection.timeout,
      method,
      fn ->
        do_request(
          connection,
          {method, path, request_headers(connection, headers), body},
          deadline
        )
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

  defp do_request(%Connection{transport: :https, pool: pool} = connection, request, deadline)
       when not is_nil(pool) and elem(request, 0) in ["GET", "HEAD"] do
    case TLS.snapshot(connection) do
      {:ok, key, snapshot} -> checkout(connection, pool, key, snapshot, request, deadline)
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp do_request(connection, request, deadline) do
    fresh_request(open(connection, deadline), request, connection, deadline)
  end

  defp checkout(connection, pool, key, snapshot, request, deadline) do
    case ConnectionPool.checkout(pool, key, deadline, fn from, idle, age, acquisition ->
           pooled_request(connection, request, deadline, snapshot, from, idle, age, acquisition)
         end) do
      :miss ->
        fresh_request(
          open_snapshot(connection, deadline, snapshot),
          request,
          connection,
          deadline
        )

      result ->
        result
    end
  end

  defp fresh_request({:ok, socket}, request, connection, deadline) do
    case exchange(socket, request, connection, deadline) do
      {:ok, _socket, response} -> {:ok, response}
      error -> error
    end
  after
    Mint.HTTP.close(socket)
  end

  defp fresh_request({:error, reason}, _request, _connection, _deadline),
    do: {:error, %Error{kind: connect_error(reason)}}

  defp pooled_request(connection, request, deadline, snapshot, from, idle, age, acquisition) do
    case reusable(idle, age, acquisition, deadline) do
      {:ok, socket, opened} ->
        pooled_exchange(socket, opened, request, connection, deadline, from)

      :miss ->
        pooled_fresh(
          open_snapshot(connection, deadline, snapshot),
          request,
          connection,
          deadline,
          from
        )
    end
  end

  defp pooled_fresh({:ok, socket}, request, connection, deadline, from),
    do: pooled_exchange(socket, now(), request, connection, deadline, from)

  defp pooled_fresh({:error, reason}, _request, _connection, _deadline, _from),
    do: {{:error, %Error{kind: connect_error(reason)}}, nil}

  defp pooled_exchange(socket, opened, request, connection, deadline, from) do
    case exchange(socket, request, connection, deadline) do
      {:ok, socket, response} ->
        idle = return_socket(socket, response, opened, deadline, from)
        {{:ok, response}, idle}

      error ->
        Binding.close(socket)
        {error, nil}
    end
  end

  defp return_socket(socket, response, opened, deadline, from) do
    if response.status != 101 and Mint.HTTP.open?(socket) and
         Mint.HTTP.open_request_count(socket) == 0 do
      ConnectionPool.checkin(from, socket, opened, deadline)
    else
      Binding.close(socket)
      nil
    end
  end

  defp reusable(nil, _age, _acquisition, _deadline), do: :miss

  defp reusable({socket, opened}, age, acquisition, deadline) do
    with true <- now() - opened < age and now() < acquisition and Mint.HTTP.open?(socket),
         {:error, socket, %Mint.TransportError{reason: :timeout}, []} <-
           Mint.HTTP.recv(socket, 0, 0),
         true <- now() < acquisition and remaining(deadline) > 0,
         :ok <- :ssl.setopts(Mint.HTTP.get_socket(socket), send_timeout: remaining(deadline)) do
      {:ok, socket, opened}
    else
      _ ->
        Binding.close(socket)
        :miss
    end
  end

  defp connect_error(kind) when kind in [:deadline, :canceled], do: kind
  defp connect_error(_), do: :connection

  defp exchange(socket, {method, path, headers, body}, connection, deadline) do
    with :ok <- before_send(connection.request_context, deadline),
         {:ok, socket, ref} <- Mint.HTTP.request(socket, method, path, headers, body) do
      case receive_response(socket, ref, deadline, connection.max_response_bytes, %{
             status: nil,
             headers: %{},
             raw_headers: nil,
             trailers: [],
             header_bytes: 0,
             body: [],
             bytes: 0
           }) do
        {:error, kind} -> failed(method, kind)
        success -> success
      end
    else
      {:error, kind} -> failed(method, kind)
      {:error, _, _} -> failed(method, :request)
    end
  rescue
    _ -> failed(method, :request)
  end

  defp before_send(context, deadline) do
    if remaining(deadline) == 0, do: {:error, :deadline}, else: RequestContext.check(context)
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

  def open(%Connection{transport: :https} = connection, deadline) do
    open_https(connection.address, Connection.tls_options(connection), deadline)
  rescue
    _ -> {:error, :connection}
  end

  defp open_snapshot(connection, deadline, snapshot) do
    case before_send(connection.request_context, deadline) do
      :ok -> open_https(connection.address, TLS.options(connection, snapshot), deadline)
      error -> error
    end
  rescue
    _ -> {:error, :connection}
  end

  defp open_https(uri, options, deadline) do
    Mint.HTTP.connect(:https, uri.host, uri.port,
      protocols: [:http1],
      mode: :passive,
      log: false,
      max_header_list_size: 65_536,
      transport_opts:
        options ++
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
            {:done, acc} ->
              {:ok, socket, %{acc | body: IO.iodata_to_binary(Enum.reverse(acc.body))}}

            {:more, acc} ->
              receive_response(socket, ref, deadline, maximum, acc)

            {:error, reason} ->
              {:error, reason}
          end

        {:error, _, error, responses} ->
          {:error, response_error_kind(error, responses, acc)}
      end
    end
  end

  @doc false
  def response_error_kind(%Mint.TransportError{reason: :timeout}, _, _), do: :deadline

  # This is a parsed-observation boundary, not a claim that no raw bytes arrived.
  # Any nonempty event batch is conservatively decisive, including unknown,
  # unrelated, error and done events. Partial unparsed status lines can close
  # without a Mint event and remain indistinguishable from an early EOF.
  def response_error_kind(%Mint.TransportError{reason: :closed}, [], %{
        status: nil,
        headers: headers,
        raw_headers: nil,
        body: [],
        bytes: 0,
        header_bytes: 0
      })
      when map_size(headers) == 0, do: :response_closed

  def response_error_kind(_, _, _), do: :response

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
