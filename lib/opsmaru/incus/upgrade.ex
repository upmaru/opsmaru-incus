defmodule Opsmaru.Incus.Upgrade do
  @moduledoc false
  alias Opsmaru.Incus.{Error, Response}

  # Mint retains coalesced protocol bytes after 101 and parses rejected HTTP
  # bodies, including chunked framing. Never replay an upgrade as a second GET.
  def receive_response(conn, request, deadline, limit),
    do: receive_response(conn, request, deadline, limit, nil, [], [], 0)

  defp receive_response(conn, request, deadline, limit, status, headers, data, bytes) do
    if deadline <= System.monotonic_time(:millisecond) do
      {:error, %Error{kind: :deadline, http_status: status}}
    else
      receive_until_deadline(conn, request, deadline, limit, status, headers, data, bytes)
    end
  end

  defp receive_until_deadline(conn, request, deadline, limit, status, headers, data, bytes) do
    case Mint.HTTP.recv(conn, 0, max(0, deadline - System.monotonic_time(:millisecond))) do
      {:ok, conn, responses} ->
        {status, headers, data, bytes, done} =
          Enum.reduce(responses, {status, headers, data, bytes, false}, fn
            {:status, ^request, value}, {_, headers, data, bytes, done} ->
              {value, headers, data, bytes, done}

            {:headers, ^request, value}, {status, _, data, bytes, done} ->
              {status, value, data, bytes, done}

            {:data, ^request, value}, {status, headers, data, bytes, done} ->
              {status, headers, [value | data], bytes + byte_size(value), done}

            {:done, ^request}, {status, headers, data, bytes, _} ->
              {status, headers, data, bytes, true}

            _, acc ->
              acc
          end)

        cond do
          bytes > limit -> {:error, %Error{kind: :frame_limit, http_status: status}}
          status == 101 and headers != [] -> {:ok, conn, status, headers, data}
          done -> {:ok, conn, status, headers, data}
          true -> receive_response(conn, request, deadline, limit, status, headers, data, bytes)
        end

      {:error, _, %Mint.TransportError{reason: :timeout}, _} ->
        {:error, %Error{kind: :deadline, http_status: status}}

      _ ->
        {:error, :handshake}
    end
  end

  def rejected(status, headers, data, kind) do
    case Response.decode(IO.iodata_to_binary(Enum.reverse(data)), status, Map.new(headers)) do
      {:ok, response} ->
        {:error,
         %Error{
           kind: if(response.type == "error" or status >= 400, do: :native, else: kind),
           http_status: status,
           error_code: response.error_code,
           message: response.error,
           response: response,
           operation: response.operation
         }}

      _ ->
        {:error, %Error{kind: kind, http_status: status}}
    end
  end
end
