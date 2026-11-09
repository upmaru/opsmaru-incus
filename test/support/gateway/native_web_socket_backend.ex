defmodule Opsmaru.TestSupport.NativeWebSocketBackend do
  @moduledoc "Database-free native API and channel oracle used only by gateway client conformance fixtures."
  alias Opsmaru.TestSupport.{HTTPFixture, WebSocketFixture}

  def start(context, mode, transport \\ :unix) do
    observer = self()
    handler = fn request -> respond(request, mode, observer) end

    options =
      case transport do
        :unix ->
          [
            transport: :gen_tcp,
            path: Path.join(context.root, "native-#{System.unique_integer([:positive])}.sock")
          ]

        {:https, identity, client} ->
          [
            transport: :ssl,
            certfile: identity.certfile,
            keyfile: identity.keyfile,
            peer_options: [
              verify: :verify_peer,
              fail_if_no_peer_cert: true,
              cacertfile: client.cafile
            ]
          ]
      end

    ExUnit.Callbacks.start_supervised!({HTTPFixture, options ++ [handler: handler]},
      id: make_ref()
    )
  end

  defp respond(request, mode, observer) do
    uri = URI.parse(request.target)

    cond do
      uri.path == "/1.0" ->
        sync(%{api_version: "1.0", api_extensions: ["instances", "console"], environment: %{}})

      request.method == "POST" ->
        fds = fds(mode)

        %{
          status: 202,
          body: %{
            type: "async",
            operation: "/1.0/operations/native",
            metadata: %{id: "native", status_code: 103, metadata: %{fds: fds}}
          }
        }

      mode == :partial_console and URI.decode_query(uri.query || "")["secret"] == "0" ->
        %{
          status: 403,
          body: %{
            type: "error",
            error: "native channel rejected",
            error_code: 403,
            operation: "/1.0/operations/native"
          }
        }

      String.ends_with?(uri.path, "/websocket") or uri.path == "/1.0/events" ->
        secret = URI.decode_query(uri.query || "")["secret"] || "events"

        %{
          upgrade: fn t, s ->
            accept =
              Base.encode64(
                :crypto.hash(
                  :sha,
                  request.headers["sec-websocket-key"] <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                )
              )

            :ok =
              t.send(
                s,
                "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
              )

            send_initial(t, s, secret, mode)

            receive_frames(t, s, "", secret, mode, observer)
          end
        }

      true ->
        sync(%{id: "native", status_code: 200, status: "Success", metadata: %{return: 7}})
    end
  end

  defp send_initial(t, s, secret, mode) do
    case secret do
      "1" ->
        :ok =
          t.send(
            s,
            WebSocketFixture.frame(2, <<0, 255, 128, 10>>) <>
              WebSocketFixture.frame(1, "")
          )

      "2" ->
        :ok =
          t.send(
            s,
            WebSocketFixture.frame(2, <<254, 0, 13>>) <> WebSocketFixture.frame(1, "")
          )

      "operation" ->
        :ok = t.send(s, WebSocketFixture.frame(2, <<0, 255, 128>>))

      "0" when mode == :console ->
        :ok = t.send(s, WebSocketFixture.frame(2, <<0, 255, 128>>))

      _ ->
        :ok
    end
  end

  defp fds(mode) when mode in [:console, :interactive, :partial_console],
    do: %{"control" => "control", "0" => "0"}

  defp fds(_), do: %{"0" => "0", "1" => "1", "2" => "2"}

  defp sync(metadata),
    do: %{
      status: 200,
      body: %{type: "sync", status: "Success", status_code: 200, metadata: metadata}
    }

  defp receive_frames(t, s, buffer, secret, mode, observer) do
    case :cow_ws.parse_header(buffer, %{}, :undefined) do
      :more ->
        more(t, s, buffer, secret, mode, observer)

      {_type, _frag, _rsv, length, _mask, rest} when byte_size(rest) < length ->
        more(t, s, buffer, secret, mode, observer)

      {type, frag, rsv, length, mask, rest} ->
        {:ok, payload, _, tail} =
          :cow_ws.parse_payload(rest, mask, 0, 0, type, length, frag, %{}, rsv)

        send(observer, {:native_frame, secret, type, payload})

        if type != :close do
          reply_frame(t, s, secret, mode, type, payload)
          receive_frames(t, s, tail, secret, mode, observer)
        end
    end
  end

  defp reply_frame(t, s, "events", _, _, payload),
    do: t.send(s, WebSocketFixture.frame(1, payload))

  defp reply_frame(t, s, "0", :console, type, payload) do
    opcode = if type == :binary, do: 2, else: 1
    t.send(s, WebSocketFixture.frame(opcode, payload))
  end

  defp reply_frame(t, s, "0", :interactive, :text, _) do
    t.send(s, WebSocketFixture.frame(2, <<0, 255, 128, 10>>) <> WebSocketFixture.frame(1, ""))
  end

  defp reply_frame(_, _, _, _, _, _), do: :ok

  defp more(t, s, buffer, secret, mode, observer) do
    case t.recv(s, 0, 10_000) do
      {:ok, bytes} -> receive_frames(t, s, buffer <> bytes, secret, mode, observer)
      _ -> :ok
    end
  end
end
