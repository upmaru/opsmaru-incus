defmodule Opsmaru.Incus.DirectWebSocketReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Server, WebSocket}
  alias Opsmaru.Incus.HTTP.Response
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture}
  @driver Path.expand("../.integration/incus-direct-websocket", __DIR__)
  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./directwebsocket"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-direct-ws-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:gen_tcp, :ssl] do
    test "#{transport} direct native WebSocket preserves custom/authenticated headers and handshake metadata",
         %{root: root} do
      compare(root, unquote(transport))
    end
  end

  defp compare(root, transport) do
    identity = if transport == :ssl, do: TLSIdentity.generate(root, "ws", "localhost"), else: nil

    opts =
      if identity,
        do: [certfile: identity.certfile, keyfile: identity.keyfile],
        else: [path: Path.join(root, "socket")]

    payload = <<0, 255, 128>>

    fixture =
      start_supervised!(
        {HTTPFixture,
         [
           transport: transport,
           handler: fn request ->
             %{
               upgrade: fn adapter, socket ->
                 accept =
                   Base.encode64(
                     :crypto.hash(
                       :sha,
                       request.headers["sec-websocket-key"] <>
                         "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                     )
                   )

                 adapter.send(
                   socket,
                   "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\nETag: native-ws\r\nSet-Cookie: private-fixture-cookie\r\n\r\n" <>
                     WebSocketFixture.frame(2, payload)
                 )

                 adapter.recv(socket, 0, 3000)
               end
             }
           end
         ] ++ opts}
      )

    endpoint = HTTPFixture.endpoint(fixture)

    input =
      Map.merge(endpoint, %{
        path: "/1.0/events?project=p&target=m",
        headers: %{"x-custom" => "host-header"}
      })

    input =
      if identity,
        do:
          Map.merge(input, %{
            ca: File.read!(identity.cafile),
            cert: File.read!(identity.certfile),
            key: File.read!(identity.keyfile),
            server_cert: File.read!(identity.certfile)
          }),
        else: input

    expected = native(input)

    connection =
      if identity,
        do:
          Connection.https!(endpoint.url,
            owner: :fixture,
            project: "p",
            member: "m",
            require_authenticated: true,
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          ),
        else:
          Connection.unix!(endpoint.socket,
            owner: :fixture,
            project: "p",
            member: "m",
            require_authenticated: true
          )

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{}
    }

    assert {:ok, channel} =
             WebSocket.open(client, "/1.0/events", headers: [{"x-custom", "host-header"}])

    assert {:ok, response} = WebSocket.upgrade_response(channel)
    assert response.status == expected["status"]
    assert Response.header(response, "ETag") == expected["etag"]
    assert response.connection == connection
    assert response.identity == :verified
    assert response.body == nil
    assert {:ok, {:binary, ^payload}} = WebSocket.recv(channel)
    assert Base.decode64!(expected["body"]) == payload
    assert Response.header(response, "Set-Cookie") == "private-fixture-cookie"
    refute inspect(response) =~ "private-fixture-cookie"
    assert :ok = WebSocket.close(channel)
    assert [native, actual] = HTTPFixture.requests(fixture)
    assert native.target == actual.target
    assert actual.headers["x-custom"] == native.headers["x-custom"]
    assert actual.headers["x-incus-authenticated"] == native.headers["x-incus-authenticated"]
  end

  test "protected headers, duplicates and unknown options fail before socket access", %{
    root: root
  } do
    client = %Incus{
      connection: Connection.unix!(Path.join(root, "never-opened"), owner: :fixture),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{}
    }

    for opts <- [
          [headers: [{"sec-websocket-key", "override"}]],
          [headers: [{"authorization", "private"}]],
          [headers: [{"x-custom", "bad\nvalue"}]],
          [headers: [], headers: []],
          [unknown: true],
          %{}
        ] do
      assert {:error, %Error{kind: :invalid_websocket_options}} =
               WebSocket.open(client, "/1.0/events", opts)
    end

    refute File.exists?(client.connection.address)
  end

  defp native(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    out = collect(port, "")
    Jason.decode!(out)
  end

  defp collect(port, out) do
    receive do
      {^port, {:data, bytes}} -> collect(port, out <> bytes)
      {^port, {:exit_status, 0}} -> out
      {^port, {:exit_status, status}} -> flunk("native WebSocket oracle exit #{status}: #{out}")
    after
      5000 ->
        Port.close(port)
        flunk("native WebSocket oracle deadline")
    end
  end
end
