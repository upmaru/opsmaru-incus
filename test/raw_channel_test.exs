defmodule Opsmaru.Incus.RawChannelTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Context
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Connection
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.RawChannel
  alias Opsmaru.Incus.Server
  alias Opsmaru.Incus.Upgrade
  alias Opsmaru.TestSupport.HTTPFixture
  alias Opsmaru.TestSupport.TLSIdentity

  setup do
    root = Path.join(System.tmp_dir!(), "op-raw-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    %{root: root, context: context}
  end

  for protocol <- ["sftp", "nbd"] do
    test "#{protocol} caller loss closes a stalled upgrade before its request deadline", %{
      root: root,
      context: context
    } do
      parent = self()

      fixture =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(root, "stalled"),
           handler: fn _ ->
             %{
               upgrade: fn transport, socket ->
                 send(parent, :negotiating)
                 send(parent, {:peer_closed, transport.recv(socket, 0, 1_000)})
               end
             }
           end}
        )

      connection =
        Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture, timeout: 5_000)

      client = %Incus{
        connection: connection,
        context: context,
        server: %Server{api_extensions: []}
      }

      caller =
        spawn(fn -> RawChannel.open(client, "/1.0/instances/fixture/sftp", unquote(protocol)) end)

      on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
      assert_receive :negotiating, 1_000
      Process.exit(caller, :kill)
      assert_receive {:peer_closed, {:error, :closed}}, 500
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end

    test "#{protocol} caller loss stops a blocked raw write within the owner grace", %{
      root: root,
      context: context
    } do
      parent = self()
      protocol = unquote(protocol)

      fixture =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(root, "blocked-write"),
           handler: fn _ ->
             %{
               upgrade: fn transport, socket ->
                 :ok =
                   transport.send(
                     socket,
                     "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: #{protocol}\r\n\r\n"
                   )

                 receive do
                   :never -> :ok
                 after
                   10_000 -> :ok
                 end
               end
             }
           end}
        )

      connection =
        Connection.unix!(HTTPFixture.endpoint(fixture).socket,
          owner: :fixture,
          timeout: 5_000,
          stream_timeout: 30_000,
          max_chunk_bytes: 1_048_576,
          max_stream_bytes: 67_108_864
        )

      client = %Incus{
        connection: connection,
        context: context,
        server: %Server{api_extensions: []}
      }

      caller =
        spawn(fn ->
          {:ok, channel} = RawChannel.open(client, "/1.0/instances/fixture/sftp", protocol)
          send(parent, {:raw_writer, channel})

          receive do
            :write -> :ok
          end

          Enum.reduce_while(1..64, nil, fn _, _ ->
            case RawChannel.send_data(channel, :binary.copy(<<7>>, 1_048_576)) do
              :ok -> {:cont, nil}
              error -> {:halt, error}
            end
          end)
        end)

      on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
      assert_receive {:raw_writer, channel}, 1_000
      on_exit(fn -> if Process.alive?(channel.pid), do: Process.exit(channel.pid, :kill) end)
      :ok = :inet.setopts(:sys.get_state(channel.pid).socket, sndbuf: 1024)
      send(caller, :write)
      await_raw_write(channel.pid, System.monotonic_time(:millisecond) + 1_000)
      monitor = Process.monitor(channel.pid)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, :killed}, 500
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  defp await_raw_write(pid, deadline) do
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)

    unless Enum.any?(stack, fn {module, function, _, _} ->
             module == :prim_inet and function == :send
           end) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      await_raw_write(pid, deadline)
    end
  end

  for protocol <- ["sftp", "nbd"] do
    test "#{protocol} preserves coalesced bytes and writes after backend half-close", %{
      root: root,
      context: context
    } do
      protocol = unquote(protocol)
      initial = <<0, 255, 128, 13, 10, 0>>
      {client, fixture} = fixture(root, context, protocol, initial, true)

      {:ok, channel} =
        if protocol == "sftp",
          do: Incus.sftp(client, "fixture"),
          else: Incus.nbd(client, "fixture", reuse: true)

      assert {:ok, ^initial} = RawChannel.recv(channel)
      assert :eof = RawChannel.recv(channel)
      bytes = <<255, 0, 128, 42>>
      assert :ok = RawChannel.send_data(channel, bytes)
      assert_receive {:request, request}, 5_000
      assert String.downcase(request) =~ "upgrade: #{protocol}"
      if protocol == "nbd", do: assert(request =~ "reuse=1")
      assert_receive {:payload, ^bytes}, 5_000
      assert :ok = RawChannel.close(channel)
      refute Process.alive?(channel.pid)
      Process.exit(fixture, :kill)
    end
  end

  test "duplex bytes, explicit local close and lifetime cleanup stay bounded", %{
    root: root,
    context: context
  } do
    {client, fixture} = fixture(root, context, "sftp", <<0, 255, 128>>, false)
    {:ok, channel} = Incus.sftp(client, "fixture")
    assert {:ok, <<0, 255, 128>>} = RawChannel.recv(channel)
    assert :ok = RawChannel.send_data(channel, <<255, 0, 128, 42>>)
    assert {:ok, <<255, 0, 128, 42>>} = RawChannel.recv(channel)
    assert :ok = RawChannel.shutdown_write(channel)
    assert :ok = RawChannel.close(channel)
    Process.exit(fixture, :kill)

    {client, fixture} = fixture(root, context, "sftp", "", false)
    client = %{client | connection: %{client.connection | stream_timeout: 50}}
    {:ok, channel} = Incus.sftp(client, "fixture")
    monitor = Process.monitor(channel.pid)
    ref = channel.ref
    assert_receive {^ref, :error, %Error{kind: :deadline}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    Process.exit(fixture, :kill)
  end

  test "bad upgrade framing fails, readiness and extension failures never open a backend", %{
    root: root,
    context: context
  } do
    {client, fixture} = fixture(root, context, "websocket", "", false)
    assert {:error, %Error{kind: :upgrade_failed}} = Incus.sftp(client, "fixture")
    Process.exit(fixture, :kill)
    client = %{client | context: %{context | ready?: fn -> false end}}
    assert {:error, %Error{kind: :host_not_ready}} = Incus.sftp(client, "fixture")

    assert {:error, %Error{kind: :unsupported_extension}} =
             Incus.nbd(%{client | server: %Server{api_extensions: []}}, "fixture")
  end

  test "native Unix/TLS rejected upgrades preserve chunked envelopes and never replay", %{
    root: root,
    context: context
  } do
    identity = TLSIdentity.generate(root, "raw-rejected", "localhost")

    body =
      Jason.encode!(%{
        type: "error",
        error_code: 777,
        error: "private-native-rejection",
        operation: "/1.0/operations/native"
      })

    for transport <- [:gen_tcp, :ssl], protocol <- ["sftp", "nbd"] do
      opts =
        if transport == :gen_tcp,
          do: [path: Path.join(root, "rejected-#{protocol}")],
          else: [certfile: identity.certfile, keyfile: identity.keyfile]

      fixture =
        start_supervised!(
          {HTTPFixture,
           [
             transport: transport,
             handler: fn _ ->
               head =
                 "HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\nETag: native-rejection\r\n\r\n"

               chunk = Integer.to_string(byte_size(body), 16) <> "\r\n" <> body <> "\r\n0\r\n\r\n"
               %{wire_chunks: [{0, head}, {5, chunk}]}
             end
           ] ++ opts},
          id: make_ref()
        )

      endpoint = HTTPFixture.endpoint(fixture)

      connection =
        if transport == :gen_tcp,
          do: Connection.unix!(endpoint.socket, owner: :fixture),
          else:
            Connection.https!(endpoint.url,
              owner: :fixture,
              tls: [
                cacertfile: identity.cafile,
                certfile: identity.certfile,
                keyfile: identity.keyfile
              ]
            )

      client = %Incus{
        connection: connection,
        context: context,
        server: %Server{api_extensions: ["instance_nbd"]}
      }

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          if protocol == "sftp",
            do: Incus.sftp(client, "fixture"),
            else: Incus.nbd(client, "fixture")
        end)

      assert {:error,
              %Error{
                kind: :native,
                http_status: 403,
                error_code: 777,
                message: "private-native-rejection",
                operation: "/1.0/operations/native",
                response: response
              } = error} = result

      assert response.etag == "native-rejection"
      assert response.connection == connection
      assert response.identity == context.identity
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
      refute inspect(error) =~ "private-native-rejection"
      refute log =~ "private-native-rejection"
    end
  end

  test "raw rejected upgrades bound their response bytes and handshake deadline", %{
    root: root,
    context: context
  } do
    body = Jason.encode!(%{type: "error", error_code: 777, error: String.duplicate("x", 1024)})

    for {name, delay, budgets, kind} <- [
          {"oversized", 0, [max_response_bytes: 128], :frame_limit},
          {"silent", 100, [timeout: 30], :deadline}
        ] do
      fixture =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(root, name),
           handler: fn _ ->
             %{
               wire_chunks: [
                 {delay,
                  "HTTP/1.1 403 Forbidden\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <> body}
               ]
             }
           end},
          id: make_ref()
        )

      connection =
        Connection.unix!(HTTPFixture.endpoint(fixture).socket, [owner: :fixture] ++ budgets)

      client = %Incus{
        connection: connection,
        context: context,
        server: %Server{api_extensions: []}
      }

      assert {:error, %Error{kind: ^kind}} = Incus.sftp(client, "fixture")
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  test "blocked native writes respect the stream lifetime and release their socket", %{
    root: root,
    context: context
  } do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "blocked-write"),
         handler: fn _ ->
           %{
             wire_chunks: [
               {0,
                "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: sftp\r\n\r\n"},
               {1000, ""}
             ]
           }
         end}
      )

    connection =
      Connection.unix!(HTTPFixture.endpoint(fixture).socket,
        owner: :fixture,
        timeout: 1000,
        stream_timeout: 80,
        max_chunk_bytes: 1_048_576
      )

    client = %Incus{connection: connection, context: context, server: %Server{api_extensions: []}}
    assert {:ok, channel} = Incus.sftp(client, "fixture")
    # Constrain the disposable client socket so the fixture's unread peer
    # eventually reaches write pressure; no private state is logged.
    socket = :sys.get_state(channel.pid).socket
    assert :ok = :inet.setopts(socket, sndbuf: 1024)
    monitor = Process.monitor(channel.pid)
    before = System.monotonic_time(:millisecond)

    bytes = :binary.copy(<<7>>, 1_048_576)

    result =
      Enum.reduce_while(1..64, :still_buffering, fn _, _ ->
        case RawChannel.send_data(channel, bytes) do
          :ok -> {:cont, :still_buffering}
          error -> {:halt, error}
        end
      end)

    assert {:error, %Error{kind: kind}} = result
    assert kind in [:deadline, :channel_closed]

    if kind == :channel_closed do
      ref = channel.ref
      assert_receive {^ref, :error, %Error{kind: :deadline}}, 1000
    end

    assert System.monotonic_time(:millisecond) - before < 500
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1000
    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  test "an already exhausted upgrade budget fails before attempting another socket read" do
    deadline = System.monotonic_time(:millisecond) - 1

    assert {:error, %Error{kind: :deadline}} =
             Upgrade.receive_response(nil, make_ref(), deadline, 128)
  end

  defp fixture(root, context, protocol, initial, half_close) do
    path = Path.join(root, "s-#{System.unique_integer([:positive])}")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    fixture =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, {:request, request})

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: ",
            protocol,
            "\r\n\r\n",
            initial
          ])

        if half_close, do: :gen_tcp.shutdown(socket, :write)

        case :gen_tcp.recv(socket, 4, 5_000) do
          {:ok, payload} ->
            send(parent, {:payload, payload})
            if not half_close, do: :gen_tcp.send(socket, payload)

          _ ->
            :ok
        end

        receive do
          :close -> :ok
        after
          5_000 -> :ok
        end

        :gen_tcp.close(socket)
      end)

    on_exit(fn -> if Process.alive?(fixture), do: Process.exit(fixture, :kill) end)

    client = %Incus{
      connection: Connection.unix!(path, owner: :fixture),
      context: context,
      server: %Server{api_extensions: ["instance_nbd"]}
    }

    {client, fixture}
  end
end
