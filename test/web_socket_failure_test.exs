defmodule Opsmaru.Incus.WebSocketFailureTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus

  alias Opsmaru.Incus.{
    Connection,
    Context,
    Error,
    EventListener,
    Migration,
    Operation,
    Response,
    Server,
    WebSocket
  }

  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  setup do
    root = Path.join(System.tmp_dir!(), "op-wsf-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:gen_tcp, :ssl] do
    test "#{transport} blocked writes obey stream lifetime rather than handshake budget", %{
      root: root
    } do
      {client, fixture, _tag} =
        peer(root, unquote(transport),
          timeout: 1_500,
          stream_timeout: 100,
          max_response_bytes: 1_048_576,
          max_stream_bytes: 67_108_864
        )

      assert {:ok, channel} = WebSocket.open(client, "/1.0/events")
      state = :sys.get_state(channel.pid)
      socket = Mint.HTTP.get_socket(state.conn)
      assert :ok = small_socket_buffer(unquote(transport), socket)

      monitor = Process.monitor(channel.pid)
      started = System.monotonic_time(:millisecond)
      bytes = :binary.copy(<<7>>, 1_048_576)

      result =
        Enum.reduce_while(1..64, :still_buffering, fn _, _ ->
          case WebSocket.send_frame(channel, {:binary, bytes}) do
            :ok -> {:cont, :still_buffering}
            error -> {:halt, error}
          end
        end)

      assert {:error, %Error{kind: kind}} = result
      assert System.monotonic_time(:millisecond) - started < 700
      assert kind in [:deadline, :channel_closed]
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end

    test "#{transport} transport loss fails a pending reader without a clean EOF notice", %{
      root: root
    } do
      {client, fixture, tag} = peer(root, unquote(transport))
      assert {:ok, channel} = WebSocket.open(client, "/1.0/events")
      assert_receive {:peer, ^tag, process}, 1_000
      reader = Task.async(fn -> WebSocket.recv(channel, 1_000) end)
      await_reader(channel, System.monotonic_time(:millisecond) + 1_000)
      monitor = Process.monitor(channel.pid)
      send(process, :drop)
      assert {:error, %Error{kind: :channel_io}} = Task.await(reader)
      ref = channel.ref
      assert_receive {^ref, :error, %Error{kind: :channel_io}}, 1_000
      refute_received {^ref, :eof}
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  test "transport loss makes listener wait fail rather than recording successful completion", %{
    root: root
  } do
    {client, fixture, tag} = peer(root, :gen_tcp)
    assert {:ok, listener} = EventListener.open(client)
    assert_receive {:peer, ^tag, process}, 1_000
    send(process, :drop)
    assert {:error, %Error{kind: :channel_io}} = EventListener.wait(listener, 1_000)
    assert {:error, %Error{kind: :channel_io}} = EventListener.wait(listener, 1_000)
    refute EventListener.active?(listener)
    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  test "transport loss fails migration relay and retains both accepted operations without cancelling",
       %{root: root} do
    {source, source_fixture, source_tag} = peer(root, :gen_tcp)
    {target, target_fixture, target_tag} = peer(root, :gen_tcp)

    migration = %Migration{
      mode: :relay,
      source: operation(source, "source"),
      target: operation(target, "target")
    }

    relay = Task.async(fn -> Migration.relay(migration, timeout: 1_000) end)
    assert_receive {:peer, ^source_tag, source_peer}, 1_000
    assert_receive {:peer, ^target_tag, _}, 1_000
    send(source_peer, :drop)

    assert {:error, %Error{response: %{accepted: ^migration, error: %Error{kind: kind}}}} =
             Task.await(relay)

    # A pump scheduled after actor termination observes the closed local handle.
    assert kind in [:channel_io, :channel_closed]

    for fixture <- [source_fixture, target_fixture] do
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  defp operation(client, id) do
    response = %Response{
      type: "async",
      operation: "/1.0/operations/" <> id,
      connection: client.connection,
      identity: client.context.identity,
      metadata: %{"id" => id, "metadata" => %{"control" => "private-control"}}
    }

    {:ok, operation} = Operation.from_response(client, response)
    operation
  end

  defp await_reader(channel, deadline) do
    if is_nil(:sys.get_state(channel.pid).pending) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      await_reader(channel, deadline)
    end
  end

  defp small_socket_buffer(:ssl, socket), do: :ssl.setopts(socket, sndbuf: 1024)
  defp small_socket_buffer(:gen_tcp, socket), do: :inet.setopts(socket, sndbuf: 1024)

  defp peer(root, transport, budgets \\ []) do
    identity =
      if transport == :ssl,
        do: TLSIdentity.generate(root, "tls-#{System.unique_integer([:positive])}", "localhost")

    owner = self()
    ref = make_ref()

    options =
      if identity,
        do: [certfile: identity.certfile, keyfile: identity.keyfile],
        else: [path: Path.join(root, "s-#{System.unique_integer([:positive])}")]

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

                 :ok =
                   adapter.send(
                     socket,
                     "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
                   )

                 send(owner, {:peer, ref, self()})

                 receive do
                   :drop -> :ok
                 after
                   2_000 -> :ok
                 end
               end
             }
           end
         ] ++ options},
        id: ref
      )

    endpoint = HTTPFixture.endpoint(fixture)

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            [
              owner: :fixture,
              tls: [
                cacertfile: identity.cafile,
                certfile: identity.certfile,
                keyfile: identity.keyfile
              ]
            ] ++ budgets
          ),
        else: Connection.unix!(endpoint.socket, [owner: :fixture] ++ budgets)

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{}
    }

    {client, fixture, ref}
  end
end
