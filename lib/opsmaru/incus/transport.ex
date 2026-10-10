defmodule Opsmaru.Incus.Transport do
  @moduledoc false
  alias Opsmaru.Incus.{Connection, Error}

  # One passive connection per request. No pool/global remote/reconnect/retry.
  def request(connection, method, path, headers, body) do
    bounded(connection.timeout, method, fn ->
      do_request(connection, method, path, headers, body)
    end)
  end

  @doc false
  def bounded(timeout, method, fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> failed(method, :request)
        catch
          _, _ -> failed(method, :request)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> failed(method, :deadline)
    end
  end

  defp do_request(connection, method, path, headers, body) do
    deadline = now() + connection.timeout

    case open(connection, deadline) do
      {:ok, socket} ->
        try do
          case Mint.HTTP.request(socket, method, path, headers, body) do
            {:ok, socket, ref} ->
              receive_response(socket, ref, deadline, connection.max_response_bytes, %{
                status: nil,
                headers: %{},
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

        {:error, _, _, _} ->
          {:error, :response}
      end
    end
  end

  defp collect([], _, _, acc), do: {:more, acc}

  defp collect([{:status, ref, status} | rest], ref, maximum, acc),
    do: collect(rest, ref, maximum, %{acc | status: status})

  defp collect([{:headers, ref, headers} | rest], ref, maximum, acc),
    do: collect(rest, ref, maximum, %{acc | headers: Map.merge(acc.headers, Map.new(headers))})

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
