defmodule Opsmaru.Incus.TLSStreamTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, RawChannel, Server, WebSocket}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture}

  test "verified HTTPS upgrades preserve coalesced raw and WebSocket binary bytes" do
    root = Path.join(System.tmp_dir!(), "op-tls-stream-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    identity = TLSIdentity.generate(root, "stream", "localhost")
    bytes = <<0, 255, 128>>

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: identity.certfile,
         keyfile: identity.keyfile,
         handler: fn request ->
           if request.headers["upgrade"] == "websocket" do
             accept =
               Base.encode64(
                 :crypto.hash(
                   :sha,
                   request.headers["sec-websocket-key"] <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                 )
               )

             %{
               raw: [
                 "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
                 accept,
                 "\r\n\r\n",
                 WebSocketFixture.frame(2, bytes),
                 WebSocketFixture.frame(8, <<1000::16>>)
               ]
             }
           else
             %{
               raw: [
                 "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: sftp\r\n\r\n",
                 bytes
               ]
             }
           end
         end}
      )

    endpoint = HTTPFixture.endpoint(fixture)

    connection =
      Connection.https!(endpoint.url,
        owner: :fixture,
        tls: [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
      )

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: []}
    }

    assert {:ok, raw} = Incus.sftp(client, "fixture")
    assert {:ok, ^bytes} = RawChannel.recv(raw)
    RawChannel.close(raw)
    assert {:ok, ws} = WebSocket.open(client, "/1.0/events")
    assert {:ok, {:binary, ^bytes}} = WebSocket.recv(ws)
    assert :eof = WebSocket.recv(ws)
    assert {:error, %{kind: :channel_closed}} = WebSocket.send_frame(ws, {:binary, bytes})
    WebSocket.close(ws)
    refute Process.alive?(ws.pid)
  end
end
