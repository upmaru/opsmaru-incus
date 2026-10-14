defmodule Opsmaru.Incus.AuthenticatedHeaderTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Events, RawChannel, Server, Transfer}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  setup do
    root = Path.join(System.tmp_dir!(), "op-auth-header-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} authenticated requirement stays connection-local across HTTP, transfers and upgrades",
         %{root: root} do
      verify_frontends(root, unquote(transport))
    end
  end

  defp verify_frontends(root, transport) do
    identity = if transport == :https, do: TLSIdentity.generate(root, "auth", "localhost")

    options =
      if identity,
        do: [transport: :ssl, certfile: identity.certfile, keyfile: identity.keyfile],
        else: [transport: :gen_tcp, path: Path.join(root, "s")]

    fixture =
      start_supervised!(
        {HTTPFixture,
         options ++
           [
             handler: fn request ->
               case URI.parse(request.target).path do
                 "/1.0/events" ->
                   accept =
                     Base.encode64(
                       :crypto.hash(
                         :sha,
                         request.headers["sec-websocket-key"] <>
                           "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                       )
                     )

                   %{
                     wire_chunks: [
                       {0,
                        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"},
                       {500, ""}
                     ]
                   }

                 "/1.0/instances/native/sftp" ->
                   %{
                     wire_chunks: [
                       {0,
                        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: sftp\r\n\r\n"},
                       {500, ""}
                     ]
                   }

                 "/1.0/binary" ->
                   %{raw: "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"}

                 _ ->
                   %{status: 200, body: %{type: "sync", metadata: %{}}}
               end
             end
           ]}
      )

    endpoint = HTTPFixture.endpoint(fixture)

    connection =
      if identity,
        do:
          Connection.https!(endpoint.url,
            owner: :fixture,
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          ),
        else: Connection.unix!(endpoint.socket, owner: :fixture)

    context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    original = %Incus{connection: connection, context: context, server: %Server{}}

    for flag <- [true, false] do
      client = %{original | connection: %{connection | require_authenticated: flag}}
      assert {:ok, _} = Incus.raw_query(client, "GET", "/1.0/native")
      assert {:ok, _} = Transfer.download(client, "/1.0/binary", fn "x" -> :ok end)
      assert {:ok, _} = Transfer.upload(client, "/1.0/upload", [<<0, 255, 128>>])
      assert {:ok, channel} = Incus.sftp(client, "native")
      RawChannel.close(channel)
      assert {:ok, channel} = Events.subscribe(client)
      Events.close(channel)
      requests = HTTPFixture.requests(fixture) |> Enum.take(-5)
      assert length(requests) == 5

      assert Enum.all?(requests, fn request ->
               request.headers["x-incus-authenticated"] == if(flag, do: "true", else: nil)
             end)

      refute original.connection.require_authenticated
    end
  end

  test "native authenticated flag rejects non-boolean host configuration", %{root: root} do
    for flag <- [nil, "true", 1] do
      assert_raise ArgumentError, "require_authenticated must be a boolean", fn ->
        Connection.unix!(Path.join(root, "unopened"),
          owner: :fixture,
          require_authenticated: flag
        )
      end
    end

    assert File.ls!(root) == []
  end
end
