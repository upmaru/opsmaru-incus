defmodule Opsmaru.Incus.Gateway.UpgradeResponse do
  @moduledoc false
  # Gateway-only Mint handshake collector. Keep the original native response
  # headers when a rejected chunked response also carries trailers. Never use
  # trailer fields to replace status, validators or operation identity.
  alias Opsmaru.Incus.Gateway.Headers

  def receive_response(conn, ref, deadline, limit, header_limit \\ 65_536) do
    state = %{status: nil, headers: nil, body: [], bytes: 0, header_bytes: 0}
    receive_response(conn, ref, deadline, limit, header_limit, state)
  end

  defp receive_response(conn, ref, deadline, limit, header_limit, state) do
    left = deadline - System.monotonic_time(:millisecond)

    if left > 0 do
      case Mint.HTTP.recv(conn, 0, left) do
        {:ok, conn, responses} ->
          collected(
            conn,
            ref,
            deadline,
            limit,
            header_limit,
            collect(responses, ref, state, limit, header_limit)
          )

        _ ->
          {:error, :upgrade_response}
      end
    else
      {:error, :deadline}
    end
  end

  defp collected(conn, ref, deadline, limit, header_limit, {:ok, state, done}) do
    if done or (state.status == 101 and is_list(state.headers)),
      do: {:ok, conn, state.status, state.headers || [], state.body},
      else: receive_response(conn, ref, deadline, limit, header_limit, state)
  end

  defp collected(_, _, _, _, _, :error), do: {:error, :invalid_upgrade_response}

  defp collect([], _, state, _, _), do: {:ok, state, false}

  defp collect([{:status, ref, status} | tail], ref, state, limit, header_limit),
    do: collect(tail, ref, %{state | status: status, headers: nil}, limit, header_limit)

  defp collect([{:headers, ref, headers} | tail], ref, state, limit, header_limit) do
    bytes =
      state.header_bytes +
        Enum.reduce(headers, 0, fn {name, value}, size ->
          size + byte_size(name) + byte_size(value) + 4
        end)

    if bytes <= header_limit and valid_headers?(state.headers, headers) do
      original = state.headers || headers
      collect(tail, ref, %{state | headers: original, header_bytes: bytes}, limit, header_limit)
    else
      :error
    end
  end

  defp collect([{:data, ref, bytes} | tail], ref, state, limit, header_limit) do
    size = state.bytes + byte_size(bytes)

    if size <= limit,
      do:
        collect(
          tail,
          ref,
          %{state | bytes: size, body: [bytes | state.body]},
          limit,
          header_limit
        ),
      else: :error
  end

  defp collect([{:done, ref} | _], ref, state, _, _), do: {:ok, state, true}
  defp collect(_, _, _, _, _), do: :error

  defp valid_headers?(nil, headers), do: match?({:ok, _}, Headers.response(headers))

  defp valid_headers?(_, trailers) do
    forbidden = ~w(content-length transfer-encoding connection upgrade host trailer)

    Enum.all?(trailers, fn {name, _} -> name not in forbidden end) and
      match?({:ok, _}, Headers.trailers(trailers))
  end
end
