defmodule Opsmaru.Incus.RawChannelTest do
  # Its write-pressure tests set VM-wide trace patterns on :inet/:ssl setopts/2 under TraceLock.
  use ExUnit.Case, async: true
  import Opsmaru.TestSupport.Monitor, only: [monitor!: 1]
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Connection
  alias Opsmaru.Incus.Context
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.RawChannel
  alias Opsmaru.Incus.Server
  alias Opsmaru.Incus.Upgrade
  alias Opsmaru.TestSupport.CleanupAssertions, as: Cleanup
  alias Opsmaru.TestSupport.HTTPFixture
  alias Opsmaru.TestSupport.TLSIdentity
  alias Opsmaru.TestSupport.TraceLock

  @transports [{:gen_tcp, "unix"}, {:ssl, "mutual HTTPS"}]

  setup do
    root = Path.join(System.tmp_dir!(), "op-raw-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    %{root: root, context: context}
  end

  for {transport, label} <- @transports, protocol <- ["sftp", "nbd"] do
    test "#{label} #{protocol} caller loss closes a stalled upgrade before its request deadline",
         %{
           root: root,
           context: context
         } do
      parent = self()
      identity = identity(unquote(transport), root)

      fixture =
        start_supervised!(
          {HTTPFixture,
           listener(unquote(transport), root, "stalled", identity) ++
             [
               handler: fn _ ->
                 %{
                   upgrade: fn transport, socket ->
                     send(parent, :negotiating)
                     send(parent, {:peer_closed, transport.recv(socket, 0, 30_000)})
                   end
                 }
               end
             ]}
        )

      connection = connect(fixture, identity, owner: :fixture, timeout: 30_000)

      client = %Incus{
        connection: connection,
        context: context,
        server: %Server{api_extensions: []}
      }

      caller =
        spawn(fn -> RawChannel.open(client, "/1.0/instances/fixture/sftp", unquote(protocol)) end)

      on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
      assert_receive :negotiating, 5_000
      Process.exit(caller, :kill)
      assert_receive {:peer_closed, {:error, :closed}}, 5_000
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end

    test "#{label} #{protocol} caller loss releases a blocked raw write", %{
      root: root,
      context: context
    } do
      parent = self()
      protocol = unquote(protocol)
      transport = unquote(transport)
      identity = identity(transport, root)

      fixture =
        start_supervised!(
          {HTTPFixture,
           listener(transport, root, "blocked-write", identity) ++
             [
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
                       30_000 -> :ok
                     end
                   end
                 }
               end
             ]}
        )

      connection =
        connect(fixture, identity,
          owner: :fixture,
          timeout: 30_000,
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
      assert_receive {:raw_writer, channel}, 5_000
      on_exit(fn -> if Process.alive?(channel.pid), do: Process.exit(channel.pid, :kill) end)
      :ok = small_socket_buffer(transport, :sys.get_state(channel.pid).socket)
      send(caller, :write)
      await_raw_write(channel.pid, System.monotonic_time(:millisecond) + 5_000)
      monitors = Cleanup.monitor([channel.pid])
      Process.exit(caller, :kill)
      assert :ok = Cleanup.assert_stopped(monitors)
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  defp silent_budget(:ssl), do: {1_000, 500}
  defp silent_budget(_), do: {100, 30}

  defp await_raw_write(pid, deadline) do
    unless raw_write?(pid, true) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      await_raw_write(pid, deadline)
    end
  end

  # Unix channels write in prim_inet; TLS channels wait on their monitored TLS
  # sender while that sender writes in prim_inet.
  defp raw_write?(pid, follow?) do
    info = Process.info(pid, [:current_stacktrace, :monitors]) || []

    calls =
      for {module, function, _, _} <- info[:current_stacktrace] || [], do: {module, function}

    {:prim_inet, :send} in calls or
      (follow? and {:tls_sender, :call} in calls and
         Enum.any?(info[:monitors] || [], fn
           {:process, sender} when is_pid(sender) -> raw_write?(sender, false)
           _ -> false
         end))
  end

  defp small_socket_buffer(:gen_tcp, socket), do: :inet.setopts(socket, sndbuf: 1024)
  defp small_socket_buffer(:ssl, socket), do: :ssl.setopts(socket, sndbuf: 1024)

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

  for {transport, label} <- @transports do
    test "#{label} duplex bytes, explicit local close and lifetime cleanup stay bounded", %{
      root: root,
      context: context
    } do
      transport = unquote(transport)
      {client, fixture} = fixture(root, context, "sftp", <<0, 255, 128>>, false, transport)
      {:ok, channel} = Incus.sftp(client, "fixture")
      assert {:ok, <<0, 255, 128>>} = RawChannel.recv(channel)
      assert :ok = RawChannel.send_data(channel, <<255, 0, 128, 42>>)
      assert {:ok, <<255, 0, 128, 42>>} = RawChannel.recv(channel)
      assert :ok = RawChannel.shutdown_write(channel)
      assert :ok = RawChannel.close(channel)
      Process.exit(fixture, :kill)

      {client, fixture} = fixture(root, context, "sftp", "", false, transport)
      # Long enough to open the channel on a loaded VM before its lifetime ends.
      client = %{client | connection: %{client.connection | stream_timeout: 500}}
      {:ok, channel} = Incus.sftp(client, "fixture")
      monitor = monitor!(channel.pid)
      ref = channel.ref
      assert_receive {^ref, :error, %Error{kind: :deadline}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 2_000
      Process.exit(fixture, :kill)
    end

    test "#{label} bad upgrade framing fails, readiness and extension failures never open a backend",
         %{
           root: root,
           context: context
         } do
      {client, fixture} = fixture(root, context, "websocket", "", false, unquote(transport))
      assert {:error, %Error{kind: :upgrade_failed}} = Incus.sftp(client, "fixture")
      Process.exit(fixture, :kill)
      client = %{client | context: %{context | ready?: fn -> false end}}
      assert {:error, %Error{kind: :host_not_ready}} = Incus.sftp(client, "fixture")

      assert {:error, %Error{kind: :unsupported_extension}} =
               Incus.nbd(%{client | server: %Server{api_extensions: []}}, "fixture")
    end
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

  for {transport, label} <- @transports do
    test "#{label} raw rejected upgrades bound their response bytes and handshake deadline", %{
      root: root,
      context: context
    } do
      transport = unquote(transport)
      identity = identity(transport, root)
      body = Jason.encode!(%{type: "error", error_code: 777, error: String.duplicate("x", 1024)})

      # Over TLS the request budget also covers the handshake, so the silent peer
      # and its deadline are scaled up; the deadline still expires before any reply.
      {delay, timeout} = silent_budget(transport)

      for {name, delay, budgets, kind} <- [
            {"oversized", 0, [max_response_bytes: 128], :frame_limit},
            {"silent", delay, [timeout: timeout], :deadline}
          ] do
        fixture =
          start_supervised!(
            {HTTPFixture,
             listener(transport, root, name, identity) ++
               [
                 handler: fn _ ->
                   %{
                     wire_chunks: [
                       {delay,
                        "HTTP/1.1 403 Forbidden\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
                          body}
                     ]
                   }
                 end
               ]},
            id: make_ref()
          )

        connection = connect(fixture, identity, [owner: :fixture] ++ budgets)

        client = %Incus{
          connection: connection,
          context: context,
          server: %Server{api_extensions: []}
        }

        assert {:error, %Error{kind: ^kind}} = Incus.sftp(client, "fixture")
        assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{label} blocked writes retain stream timeout caps despite delayed observation", %{
      root: root,
      context: context
    } do
      # Before anything starts a clock: none may run while waiting for the lock.
      TraceLock.acquire!()
      transport = unquote(transport)
      identity = identity(transport, root)

      fixture =
        start_supervised!(
          {HTTPFixture,
           listener(transport, root, "blocked-write", identity) ++
             [
               handler: fn _ ->
                 %{
                   wire_chunks: [
                     {0,
                      "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: sftp\r\n\r\n"},
                     {30_000, ""}
                   ]
                 }
               end
             ]}
        )

      connection =
        connect(fixture, identity,
          owner: :fixture,
          timeout: 30_000,
          stream_timeout: 1_000,
          max_chunk_bytes: 1_048_576
        )

      client = %Incus{
        connection: connection,
        context: context,
        server: %Server{api_extensions: []}
      }

      assert {:ok, channel} = Incus.sftp(client, "fixture")
      # Constrain the disposable client socket so the fixture's unread peer
      # eventually reaches write pressure; no private state is logged.
      socket = :sys.get_state(channel.pid).socket
      assert :ok = small_socket_buffer(transport, socket)
      monitors = Cleanup.monitor([channel.pid])
      patterns = [{:inet, :setopts, 2}, {:ssl, :setopts, 2}]
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, true, [:local])

      on_exit(fn ->
        for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
      end)

      :erlang.trace(channel.pid, true, [:call])

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
        assert_receive {^ref, :error, %Error{kind: :deadline}}, 5_000
      end

      Process.sleep(600)
      assert :ok = Cleanup.assert_stopped(monitors)
      barrier = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^barrier}, 5_000
      timeouts = send_timeout_traces(channel.pid)
      assert timeouts != []
      assert Enum.all?(timeouts, &(&1 in 0..connection.stream_timeout))
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  test "an already exhausted upgrade budget fails before attempting another socket read" do
    deadline = System.monotonic_time(:millisecond) - 1

    assert {:error, %Error{kind: :deadline}} =
             Upgrade.receive_response(nil, make_ref(), deadline, 128)
  end

  defp send_timeout_traces(pid) do
    receive do
      {:trace, ^pid, :call, {module, :setopts, [_, options]}} when module in [:inet, :ssl] ->
        Keyword.get_values(options, :send_timeout) ++ send_timeout_traces(pid)
    after
      0 -> []
    end
  end

  defp identity(:gen_tcp, _root), do: nil

  defp identity(:ssl, root),
    do: TLSIdentity.generate(root, "raw-#{System.unique_integer([:positive])}", "localhost")

  # The TLS listener requires and verifies the client certificate (mutual HTTPS).
  defp listener(:gen_tcp, root, name, nil), do: [transport: :gen_tcp, path: Path.join(root, name)]

  defp listener(:ssl, _root, _name, identity),
    do: [
      transport: :ssl,
      certfile: identity.certfile,
      keyfile: identity.keyfile,
      peer_options: [
        cacertfile: identity.cafile,
        verify: :verify_peer,
        fail_if_no_peer_cert: true
      ]
    ]

  defp connect(fixture, nil, opts),
    do: Connection.unix!(HTTPFixture.endpoint(fixture).socket, opts)

  defp connect(fixture, identity, opts),
    do:
      Connection.https!(
        HTTPFixture.endpoint(fixture).url,
        opts ++
          [
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          ]
      )

  defp fixture(root, context, protocol, initial, half_close, transport \\ :gen_tcp) do
    {listener, connection} = raw_listener(transport, root)
    on_exit(fn -> transport.close(listener) end)
    parent = self()

    fixture =
      spawn(fn ->
        {:ok, socket} = raw_accept(transport, listener)
        {:ok, request} = transport.recv(socket, 0, 5_000)
        send(parent, {:request, request})

        :ok =
          transport.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: ",
            protocol,
            "\r\n\r\n",
            initial
          ])

        if half_close, do: transport.shutdown(socket, :write)

        case transport.recv(socket, 4, 5_000) do
          {:ok, payload} ->
            send(parent, {:payload, payload})
            if not half_close, do: transport.send(socket, payload)

          _ ->
            :ok
        end

        receive do
          :close -> :ok
        after
          5_000 -> :ok
        end

        transport.close(socket)
      end)

    on_exit(fn -> if Process.alive?(fixture), do: Process.exit(fixture, :kill) end)

    client = %Incus{
      connection: connection,
      context: context,
      server: %Server{api_extensions: ["instance_nbd"]}
    }

    {client, fixture}
  end

  defp raw_listener(:gen_tcp, root) do
    path = Path.join(root, "s-#{System.unique_integer([:positive])}")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

    {listener, Connection.unix!(path, owner: :fixture)}
  end

  defp raw_listener(:ssl, root) do
    identity = identity(:ssl, root)
    {:ok, _} = Application.ensure_all_started(:ssl)

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        certfile: String.to_charlist(identity.certfile),
        keyfile: String.to_charlist(identity.keyfile),
        versions: [:"tlsv1.3"],
        reuseaddr: true,
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        cacerts: Connection.ca_certificates(identity.cafile)
      ])

    {:ok, {_address, port}} = :ssl.sockname(listener)

    connection =
      Connection.https!("https://localhost:#{port}",
        owner: :fixture,
        tls: [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
      )

    {listener, connection}
  end

  defp raw_accept(:gen_tcp, listener), do: :gen_tcp.accept(listener, 5_000)

  defp raw_accept(:ssl, listener) do
    with {:ok, socket} <- :ssl.transport_accept(listener, 5_000),
         do: :ssl.handshake(socket, 5_000)
  end
end
