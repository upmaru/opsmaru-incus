defmodule Opsmaru.Incus.Transfer do
  @moduledoc """
  Native HTTP binary transfers with bounded passive reads and acknowledged sinks.

  Sources are enumerables of binary chunks. Sinks receive binary chunks and
  must return `:ok`; source/sink work is covered by the total stream deadline.
  Bodies are never JSON/base64 encoded, captured in memory or automatically
  replayed. All sockets belong to a temporary local worker and close on error,
  deadline, completion or caller exit. Source/destination files stay host-owned.
  """
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Error, Response, Transport}
  defstruct [:http_status, :headers, :bytes, :result]

  def download(client, path, sink, headers \\ []) when is_function(sink, 1),
    do: run(client, "GET", path, headers, nil, sink)

  def upload(client, path, source, headers \\ []),
    do: run(client, "POST", path, headers, source, nil)

  @doc "Native POST returning binary data, such as direct backups; failure can be uncertain."
  def download_post(client, path, source, sink, headers \\ []) when is_function(sink, 1),
    do: run(client, "POST", path, headers, source, sink)

  @doc false
  def download_events(client, path, handler, headers \\ []),
    do: run(client, "GET", path, headers, nil, {:events, handler})

  defp run(client, method, path, headers, source, sink) do
    with :ok <- Context.authorize(client.context, client.connection),
         {:ok, path} <- Incus.request_path(client.connection, path),
         :ok <- headers(headers) do
      result =
        Transport.bounded(client.connection.stream_timeout, method, fn ->
          transfer(client.connection, method, path, headers, source, sink)
        end)

      case result do
        {:ok, %Response{} = response} ->
          {:ok, %{response | connection: client.connection, identity: client.context.identity}}

        other ->
          other
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp transfer(connection, method, path, headers, source, sink) do
    deadline = now() + connection.stream_timeout

    case Transport.open(connection, deadline) do
      {:ok, socket} ->
        try do
          with {:ok, socket, ref} <-
                 Mint.HTTP.request(
                   socket,
                   method,
                   path,
                   Transport.request_headers(connection, headers),
                   if(source, do: :stream, else: nil)
                 ),
               {:ok, socket} <- upload_source(socket, ref, source, connection, deadline) do
            receive_response(socket, ref, connection, deadline, sink, %{
              method: method,
              status: nil,
              headers: %{},
              bytes: 0,
              body: []
            })
          else
            _ -> failed(method, :transfer)
          end
        after
          Mint.HTTP.close(socket)
        end

      {:error, _} ->
        {:error, %Error{kind: :connection}}
    end
  end

  defp upload_source(socket, _, nil, _, _), do: {:ok, socket}

  defp upload_source(socket, ref, source, connection, deadline) do
    result =
      Enum.reduce_while(source, {:ok, socket, 0}, fn chunk, {:ok, socket, count} ->
        if is_binary(chunk) and byte_size(chunk) <= connection.max_chunk_bytes and
             count + byte_size(chunk) <= connection.max_stream_bytes and remaining(deadline) > 0 do
          case Mint.HTTP.stream_request_body(socket, ref, chunk) do
            {:ok, socket} -> {:cont, {:ok, socket, count + byte_size(chunk)}}
            _ -> {:halt, {:error, :send}}
          end
        else
          {:halt, {:error, :stream_limit}}
        end
      end)

    with {:ok, socket, _} <- result,
         {:ok, socket} <- Mint.HTTP.stream_request_body(socket, ref, :eof),
         do: {:ok, socket}
  end

  defp receive_response(socket, ref, connection, deadline, sink, acc) do
    case Mint.HTTP.recv(socket, 0, remaining(deadline)) do
      {:ok, socket, responses} ->
        case collect(responses, ref, connection, sink, acc) do
          {:more, acc} -> receive_response(socket, ref, connection, deadline, sink, acc)
          {:done, acc} -> finish(acc, sink)
          {:error, kind} -> failed(acc.method, kind)
        end

      {:error, _, _, _} ->
        failed(acc.method, :transfer)
    end
  end

  defp collect([], _, _, _, acc), do: {:more, acc}

  defp collect([{:status, ref, status} | rest], ref, connection, sink, acc),
    do: collect(rest, ref, connection, sink, %{acc | status: status})

  defp collect([{:headers, ref, headers} | rest], ref, connection, sink, acc),
    do: collect_headers(rest, ref, connection, sink, acc, headers)

  defp collect([{:data, ref, data} | rest], ref, connection, sink, acc) do
    maximum =
      if sink && acc.status in 200..299,
        do: connection.max_stream_bytes,
        else: connection.max_response_bytes

    if acc.bytes + byte_size(data) <= maximum do
      if sink && acc.status in 200..299 do
        with :ok <- deliver(data, sink, connection.max_chunk_bytes),
             do: collect(rest, ref, connection, sink, %{acc | bytes: acc.bytes + byte_size(data)})
      else
        collect(rest, ref, connection, sink, %{
          acc
          | bytes: acc.bytes + byte_size(data),
            body: [data | acc.body]
        })
      end
    else
      {:error, :stream_limit}
    end
  end

  defp collect([{:done, ref} | _], ref, _, _, acc), do: {:done, acc}
  defp collect(_, _, _, _, _), do: {:error, :invalid_transfer}

  defp collect_headers(rest, ref, connection, sink, acc, headers) do
    acc = %{acc | headers: Map.merge(acc.headers, Map.new(headers))}

    case sink do
      {:events, handler} when acc.status in 200..299 ->
        with :ok <- handler.({:headers, acc.headers}),
             do: collect(rest, ref, connection, sink, acc)

      _ ->
        collect(rest, ref, connection, sink, acc)
    end
  end

  defp deliver(<<>>, _, _), do: :ok

  defp deliver(data, {:events, handler}, maximum),
    do: deliver(data, fn chunk -> handler.({:data, chunk}) end, maximum)

  defp deliver(data, sink, maximum) do
    size = min(byte_size(data), maximum)
    <<chunk::binary-size(size), rest::binary>> = data
    if sink.(chunk) == :ok, do: deliver(rest, sink, maximum), else: {:error, :sink_failed}
  end

  defp finish(acc, {:events, handler}) when acc.status in 200..299 do
    case handler.(:done) do
      {:ok, result} ->
        {:ok,
         %__MODULE__{
           http_status: acc.status,
           headers: acc.headers,
           bytes: acc.bytes,
           result: result
         }}

      {:error, kind} ->
        failed(acc.method, kind)
    end
  end

  defp finish(acc, sink) when not is_nil(sink) and acc.status in 200..299,
    do: {:ok, %__MODULE__{http_status: acc.status, headers: acc.headers, bytes: acc.bytes}}

  defp finish(acc, _sink) do
    with {:ok, response} <-
           Response.decode(IO.iodata_to_binary(Enum.reverse(acc.body)), acc.status, acc.headers) do
      if response.type == "error" or acc.status >= 400 do
        {:error,
         %Error{
           kind: :native,
           http_status: acc.status,
           error_code: response.error_code,
           message: response.error,
           response: response,
           operation: response.operation
         }}
      else
        {:ok, response}
      end
    else
      _ -> failed(acc.method, :invalid_response)
    end
  end

  defp headers(headers) do
    if is_list(headers) and
         Enum.all?(headers, fn {name, value} ->
           is_binary(name) and is_binary(value) and Regex.match?(~r/\A[a-z0-9-]+\z/, name) and
             not String.contains?(value, ["\r", "\n", <<0>>]) and byte_size(value) <= 16_384 and
             name not in [
               "host",
               "connection",
               "content-length",
               "transfer-encoding",
               "authorization"
             ]
         end), do: :ok, else: {:error, :invalid_headers}
  end

  defp failed(method, kind),
    do: {:error, %Error{kind: if(method == "GET", do: kind, else: :uncertain)}}

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now())
end

defimpl Inspect, for: Opsmaru.Incus.Transfer do
  def inspect(_, _), do: "#Opsmaru.Incus.Transfer<native binary handoff redacted>"
end
