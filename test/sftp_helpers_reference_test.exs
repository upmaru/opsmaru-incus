defmodule Opsmaru.Incus.SFTPHelpersReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, RequestContext, Server, SFTP}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}

  @driver Path.expand("../.integration/sftp-helpers-driver", __DIR__)
  @handle <<255, 0, 128, 42>>
  @read <<0, 255, 128, 10, 42>>
  @write <<128, 255, 0, 13, 10>>
  @ext [{"posix-rename@openssh.com", "1"}, {"future", "old"}, {"future", "new"}]

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./sftphelpers"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-sftp-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:gen_tcp, :ssl], kind <- [:instance, :volume] do
    test "#{transport} #{kind}: constructor, native packets, binary I/O, EOF and closure", %{
      root: root
    } do
      transport = unquote(transport)
      kind = unquote(kind)
      identity = identity(transport, root)
      fixture = backend(root, transport, identity)
      input = native_input(fixture, identity, kind)
      native = oracle(Map.put(input, :Steps, steps()))
      assert native["accepted"]
      assert native["extensions"]["future"] == %{"data" => Base.encode64("new"), "found" => true}
      assert native["extensions"]["absent"] == %{"data" => "", "found" => false}
      assert native["close_ok"]
      assert Enum.map(native["steps"], & &1["ok"]) == [true, true, true, false, true]
      assert native["steps"] |> Enum.at(1) |> Map.fetch!("data") == Base.encode64(@read)
      assert native["steps"] |> Enum.at(3) |> Map.fetch!("error") == "EOF"
      native_packets = packets()
      assert_receive :sftp_peer_closed
      native_request = List.last(HTTPFixture.requests(fixture))

      client = client(fixture, identity)
      assert {:ok, session} = open(client, kind)
      assert {:ok, extensions} = SFTP.extensions(session)
      assert extensions == Map.new(@ext)
      refute inspect(session) =~ "localhost"
      assert {:ok, handle} = SFTP.open(session, "dir/雪+file", :create)
      assert {:ok, @read} = SFTP.read_at(session, handle, 3, 5)
      assert :ok = SFTP.write_at(session, handle, 9, @write)
      assert :eof = SFTP.read_at(session, handle, 15, 1)
      assert :ok = SFTP.close_file(session, handle)
      assert :ok = SFTP.close(session)
      assert :ok = SFTP.close(session)
      refute Process.alive?(session.pid)
      assert packets() == native_packets
      assert_receive :sftp_peer_closed
      actual_request = List.last(HTTPFixture.requests(fixture))

      assert :ok =
               WireComparison.compare(
                 WireComparison.request(native_request),
                 WireComparison.request(actual_request)
               )
    end
  end

  test "all subset modes produce unchanged native open flags", %{root: root} do
    for mode <- [:read, :write, :read_write, :append, :create] do
      fixture = backend(root, :gen_tcp, nil)
      input = native_input(fixture, nil, :instance)

      assert oracle(
               Map.put(input, :Steps, [
                 %{Op: "open", Path: "native", Mode: Atom.to_string(mode)},
                 %{Op: "close_file"}
               ])
             )["accepted"]

      expected = packets()
      assert_receive :sftp_peer_closed
      assert {:ok, session} = open(client(fixture, nil), :instance)
      assert {:ok, handle} = SFTP.open(session, "native", mode)
      assert :ok = SFTP.close_file(session, handle)
      SFTP.close(session)
      assert packets() == expected
      assert_receive :sftp_peer_closed
    end
  end

  test "native constructor rejection matrix and cleanup", %{root: root} do
    bodies = [
      <<2, 2::32>>,
      <<2, 6::32>>,
      <<101, 0::32>>,
      <<2, 3::32, 20::32, "short">>,
      <<2>>,
      <<>>
    ]

    for body <- bodies do
      fixture = backend(root, :gen_tcp, nil, version: body, close_after_version: true)
      native = oracle(native_input(fixture, nil, :instance))
      refute native["accepted"]
      packets()
      assert_receive :sftp_peer_closed
      assert {:error, %Error{}} = open(client(fixture, nil), :instance)
      packets()
      assert_receive :sftp_peer_closed
    end
  end

  test "native status errors retain code, message and request identity", %{root: root} do
    fixture = backend(root, :gen_tcp, nil, status: 777)

    native =
      oracle(
        Map.put(native_input(fixture, nil, :instance), :Steps, [
          %{Op: "open", Path: "secret", Mode: "read"}
        ])
      )

    assert hd(native["steps"])["code"] == 777
    assert hd(native["steps"])["error"] =~ "private-denial"
    packets()
    assert_receive :sftp_peer_closed
    assert {:ok, session} = open(client(fixture, nil), :instance)

    assert {:error,
            %Error{
              kind: :sftp_status,
              error_code: 777,
              message: "private-denial",
              response: %{request_id: 1, language: "en"}
            } = error} = SFTP.open(session, "secret", :read)

    refute inspect(error) =~ "private-denial"
    SFTP.close(session)
    packets()
    assert_receive :sftp_peer_closed
  end

  test "missing volume extension, invalid segments and unready hosts reject without I/O", %{
    root: root
  } do
    fixture = backend(root, :gen_tcp, nil, extensions: [])
    native = oracle(native_input(fixture, nil, :volume))
    refute native["accepted"]
    assert native["error"] =~ "custom_volume_sftp"
    client = %{client(fixture, nil) | server: %Server{api_extensions: []}}
    assert {:error, %Error{kind: :unsupported_extension}} = open(client, :volume)
    assert {:error, %Error{kind: :invalid_arguments}} = Incus.file_sftp(client, nil)

    assert {:error, %Error{kind: :host_not_ready}} =
             open(%{client | context: %{client.context | ready?: fn -> false end}}, :instance)

    assert Enum.all?(HTTPFixture.requests(fixture), &(&1.target == "/1.0"))
  end

  test "coalesced and fragmented version packets are preserved independently", %{root: root} do
    for opts <- [[coalesced: true], [fragmented: true]] do
      fixture = backend(root, :gen_tcp, nil, opts)
      assert {:ok, session} = open(client(fixture, nil), :instance)
      assert {:ok, extensions} = SFTP.extensions(session)
      assert extensions["future"] == "new"
      SFTP.close(session)
      packets()
      assert_receive :sftp_peer_closed
    end
  end

  test "seeded versions and extension maps compare with the unchanged native constructor", %{
    root: root
  } do
    :rand.seed(:exsss, {101, 7, 31})

    for index <- 1..30 do
      extensions =
        for n <- 1..:rand.uniform(8),
            do: {"vendor#{rem(n, 3)}", :crypto.hash(:sha256, "#{index}:#{n}") |> Base.encode16()}

      body =
        <<2, 3::32>> <>
          Enum.map_join(extensions, fn {name, data} -> string(name) <> string(data) end)

      body = if rem(index, 3) == 0, do: binary_part(body, 0, byte_size(body) - 1), else: body
      fixture = backend(root, :gen_tcp, nil, version: body, close_after_version: true)

      input =
        native_input(fixture, nil, :instance)
        |> Map.put(:Extensions, Enum.uniq(Enum.map(extensions, &elem(&1, 0))))

      native = oracle(input)
      packets()
      assert_receive :sftp_peer_closed
      actual = open(client(fixture, nil), :instance)

      if native["accepted"] do
        assert {:ok, session} = actual
        assert {:ok, data} = SFTP.extensions(session)
        assert data == Map.new(extensions)

        for {name, value} <- data,
            do: assert(native["extensions"][name]["data"] == Base.encode64(value))

        SFTP.close(session)
      else
        assert {:error, %Error{}} = actual
      end

      packets()
      assert_receive :sftp_peer_closed
    end
  end

  test "native-accepted excessive extension scopes reject and close locally", %{root: root} do
    bodies = [
      <<2, 3::32>> <> string("large") <> string(String.duplicate("v", 4097)),
      <<2, 3::32>> <> Enum.map_join(1..65, fn n -> string("e#{n}") <> string("1") end)
    ]

    for body <- bodies do
      fixture = backend(root, :gen_tcp, nil, version: body, close_after_version: true)
      assert oracle(native_input(fixture, nil, :instance))["accepted"]
      packets()
      assert_receive :sftp_peer_closed
      assert {:error, %Error{kind: :sftp_protocol}} = open(client(fixture, nil), :instance)
      packets()
      assert_receive :sftp_peer_closed
    end
  end

  test "invalid arguments and foreign handles do no protocol I/O; any process may use a session",
       %{root: root} do
    fixture = backend(root, :gen_tcp, nil)
    assert {:ok, session} = open(client(fixture, nil), :instance)
    assert {:ok, handle} = SFTP.open(session, "native", :read)
    assert length(packets()) == 2
    refute inspect(handle) =~ <<255, 0>>
    assert {:error, %Error{kind: :invalid_arguments}} = SFTP.open(session, %{}, :read)

    assert {:error, _} = SFTP.open(session, "native", :unknown)

    for {offset, count} <- [
          {-1, 1},
          {0, 0},
          {0, 131_073},
          {0, "1"},
          {9_223_372_036_854_775_807, 1}
        ],
        do: assert({:error, _} = SFTP.read_at(session, handle, offset, count))

    for bytes <- ["", [], String.duplicate("x", 131_073)],
        do: assert({:error, _} = SFTP.write_at(session, handle, 0, bytes))

    foreign = %{handle | session: make_ref()}
    assert {:error, _} = SFTP.read_at(session, foreign, 0, 1)
    assert packets() == []

    # As in pkg/sftp, paths are sent as given, and the session is shared.
    for path <- ["", <<255>>, "a" <> <<0>>, String.duplicate("x", 4097)] do
      task = Task.async(fn -> SFTP.open(session, path, :read) end)
      assert {:ok, _} = Task.await(task)
      assert [<<3, _::32, length::32, ^path::binary-size(length), _::binary>>] = packets()
    end

    assert {:ok, %{"future" => "new"}} =
             Task.await(Task.async(fn -> SFTP.extensions(session) end))

    SFTP.close(session)
    assert_receive :sftp_peer_closed
  end

  test "unmatched or oversized frames close the session; malformed matched replies fail alone; dispatched writes remain uncertain",
       %{root: root} do
    replies = [
      {true, fn _, id -> <<103, id + 1::32, string(@read)::binary>> end},
      {false, fn _, id -> <<103, id::32, string(<<>>)::binary>> end},
      {false, fn _, id -> <<103, id::32, 999::32, "truncated">> end},
      {true, fn _, _ -> {:wire, <<4_294_967_295::32>>} end}
    ]

    for {fatal?, make_reply} <- replies do
      reply = fn
        3, id, _ -> <<102, id::32, string(@handle)::binary>>
        type, id, _ -> make_reply.(type, id)
      end

      fixture = backend(root, :gen_tcp, nil, reply: reply)
      assert {:ok, session} = open(client(fixture, nil), :instance)
      assert {:ok, handle} = SFTP.open(session, "native", :read)

      assert {:error, %Error{kind: kind, response: %{request_id: 2}}} =
               SFTP.write_at(session, handle, 0, @write)

      assert kind == :uncertain

      if fatal? do
        assert_receive :sftp_peer_closed
        refute Process.alive?(session.pid)
      else
        # As in pkg/sftp, a bad reply to one request leaves the connection usable.
        refute_receive :sftp_peer_closed, 100
        assert Process.alive?(session.pid)
        SFTP.close(session)
        assert_receive :sftp_peer_closed
      end

      assert Enum.map(packets(), &:binary.first/1) == [1, 3, 6]
    end
  end

  test "RPC timeout fails one write and cancellation closes the peer, retaining native write identity",
       %{
         root: root
       } do
    for cancel? <- [false, true] do
      fixture =
        backend(root, :gen_tcp, nil,
          reply: fn
            3, id, _ -> <<102, id::32, string(@handle)::binary>>
            _, _, _ -> :stall
          end
        )

      scope = RequestContext.new!(timeout: 2_000)
      parent = self()

      owner =
        spawn(fn ->
          assert {:ok, session} =
                   open(client(fixture, nil, timeout: 100, request_context: scope), :instance)

          assert {:ok, handle} = SFTP.open(session, "native", :read)
          send(parent, {:sftp_owned, session, :sys.get_state(session.pid).raw.pid})
          send(parent, {:sftp_result, SFTP.write_at(session, handle, 0, @write)})
          send(parent, {:sftp_alive, Process.alive?(session.pid)})
        end)

      assert_receive {:sftp_owned, session, raw}, 1_000
      assert_receive {:sftp_packet, <<1, _::binary>>}
      assert_receive {:sftp_packet, <<3, _::binary>>}
      assert_receive {:sftp_packet, <<6, 2::32, _::binary>>}
      if cancel?, do: RequestContext.cancel(scope)

      assert_receive {:sftp_result,
                      {:error, %Error{kind: :uncertain, response: %{request_id: 2}} = error}},
                     1_000

      assert error.response.connection == session.connection
      assert error.response.identity == :verified
      assert error.response.session == session.ref
      # A local deadline fails only its request; cancellation ends the session.
      assert_receive {:sftp_alive, alive}, 1_000
      assert alive == not cancel?

      assert_receive :sftp_peer_closed, 1_000
      refute Process.alive?(session.pid)
      eventually_dead(raw)
      eventually_dead(owner)
      assert packets() == []
    end
  end

  test "caller loss during a stalled write releases both owned processes", %{root: root} do
    fixture =
      backend(root, :gen_tcp, nil,
        reply: fn
          3, id, _ -> <<102, id::32, string(@handle)::binary>>
          _, _, _ -> :stall
        end
      )

    parent = self()

    owner =
      spawn(fn ->
        {:ok, session} = open(client(fixture, nil, timeout: 2_000), :instance)
        {:ok, handle} = SFTP.open(session, "native", :read)
        send(parent, {:sftp_owned, session, :sys.get_state(session.pid).raw.pid})
        SFTP.write_at(session, handle, 0, @write)
      end)

    assert_receive {:sftp_owned, session, raw}, 1_000
    assert_receive {:sftp_packet, <<1, _::binary>>}
    assert_receive {:sftp_packet, <<3, _::binary>>}
    assert_receive {:sftp_packet, <<6, 2::32, _::binary>>}
    Process.exit(owner, :kill)
    assert_receive :sftp_peer_closed, 1_000
    eventually_dead(session.pid)
    eventually_dead(raw)
    assert packets() == []
  end

  test "stalled initialization times out and stream lifetime closes an idle session", %{
    root: root
  } do
    fixture = backend(root, :gen_tcp, nil, stall_version: true)
    started = System.monotonic_time(:millisecond)
    assert {:error, %Error{kind: :deadline}} = open(client(fixture, nil, timeout: 80), :instance)
    assert System.monotonic_time(:millisecond) - started < 800
    assert_receive :sftp_peer_closed, 1_000
    packets()
    fixture = backend(root, :gen_tcp, nil)
    assert {:ok, session} = open(client(fixture, nil, stream_timeout: 80), :instance)
    raw = :sys.get_state(session.pid).raw.pid
    assert_receive :sftp_peer_closed, 1_000
    eventually_dead(session.pid)
    eventually_dead(raw)
    packets()
  end

  test "remote EOF closes an idle typed session and its raw channel", %{root: root} do
    fixture = backend(root, :gen_tcp, nil, idle_eof: true)
    assert {:ok, session} = open(client(fixture, nil), :instance)
    raw = :sys.get_state(session.pid).raw.pid
    assert_receive {:sftp_eof_worker, worker}
    send(worker, :close_idle)
    eventually_dead(session.pid)
    eventually_dead(raw)
    packets()
  end

  test "local stream expiry does not cancel a shared context or another session", %{root: root} do
    fixture = backend(root, :gen_tcp, nil)
    scope = RequestContext.new!(timeout: 2_000)

    assert {:ok, short} =
             open(client(fixture, nil, stream_timeout: 80, request_context: scope), :instance)

    assert {:ok, other} = open(client(fixture, nil, request_context: scope), :instance)
    assert_receive :sftp_peer_closed, 1_000
    eventually_dead(short.pid)
    assert RequestContext.status(scope) == :active
    assert Process.alive?(other.pid)
    assert {:ok, extensions} = SFTP.extensions(other)
    assert extensions["future"] == "new"
    SFTP.close(other)
    assert_receive :sftp_peer_closed
    packets()
  end

  test "failed native file close invalidates the handle without a second request", %{root: root} do
    fixture =
      backend(root, :gen_tcp, nil,
        reply: fn
          3, id, _ -> <<102, id::32, string(@handle)::binary>>
          _, id, _ -> status(id, 777, "private-close")
        end
      )

    input =
      Map.put(native_input(fixture, nil, :instance), :Steps, [
        %{Op: "open", Path: "native", Mode: "read"},
        %{Op: "close_file"},
        %{Op: "close_file"}
      ])

    native = oracle(input)
    assert native["steps"] |> Enum.at(1) |> Map.fetch!("code") == 777
    assert native["steps"] |> Enum.at(2) |> Map.fetch!("error") =~ "closed"
    expected = packets()
    assert_receive :sftp_peer_closed
    assert {:ok, session} = open(client(fixture, nil), :instance)
    assert {:ok, handle} = SFTP.open(session, "native", :read)
    assert {:error, %Error{error_code: 777}} = SFTP.close_file(session, handle)
    assert {:error, %Error{kind: :invalid_arguments}} = SFTP.close_file(session, handle)
    SFTP.close(session)
    assert packets() == expected
    assert_receive :sftp_peer_closed
  end

  test "maximum-sized binary I/O matches native and small host chunks reject writes before I/O",
       %{root: root} do
    data = :binary.copy(<<0, 255, 128, 42>>, 32_768)

    fixture =
      backend(root, :gen_tcp, nil,
        reply: fn
          3, id, _ -> <<102, id::32, string(@handle)::binary>>
          5, id, _ -> <<103, id::32, string(data)::binary>>
          _, id, _ -> status(id, 0, "")
        end
      )

    input =
      native_input(fixture, nil, :instance)
      |> Map.put(
        :Steps,
        [
          %{Op: "open", Path: "native", Mode: "read_write"},
          %{Op: "read", Offset: 0, Count: byte_size(data)},
          %{Op: "write", Offset: 1, Data: Base.encode64(data)},
          %{Op: "close_file"}
        ]
      )

    native = oracle(input)
    assert Enum.all?(native["steps"], & &1["ok"])
    expected = packets()
    assert_receive :sftp_peer_closed
    assert {:ok, session} = open(client(fixture, nil), :instance)
    assert {:ok, handle} = SFTP.open(session, "native", :read_write)
    assert {:ok, ^data} = SFTP.read_at(session, handle, 0, byte_size(data))
    assert :ok = SFTP.write_at(session, handle, 1, data)
    assert :ok = SFTP.close_file(session, handle)
    SFTP.close(session)
    assert packets() == expected
    assert_receive :sftp_peer_closed

    fixture = backend(root, :gen_tcp, nil)

    assert {:ok, session} =
             open(client(fixture, nil, max_chunk_bytes: 64, max_request_bytes: 64), :instance)

    assert {:ok, handle} = SFTP.open(session, "native", :read)
    packets()
    assert {:error, %Error{kind: :sftp_limit}} = SFTP.write_at(session, handle, 0, data)
    assert packets() == []
    assert :ok = SFTP.close_file(session, handle)
    SFTP.close(session)
    packets()
    assert_receive :sftp_peer_closed
  end

  test "partial DATA is rejected instead of silently performing more read requests", %{root: root} do
    fixture =
      backend(root, :gen_tcp, nil,
        reply: fn
          3, id, _ -> <<102, id::32, string(@handle)::binary>>
          _, id, _ -> <<103, id::32, string("short")::binary>>
        end
      )

    assert {:ok, session} = open(client(fixture, nil), :instance)
    assert {:ok, handle} = SFTP.open(session, "native", :read)
    assert {:error, %Error{kind: :sftp_protocol}} = SFTP.read_at(session, handle, 0, 10)
    assert Enum.map(packets(), &:binary.first/1) == [1, 3, 5]
    refute_receive :sftp_peer_closed, 100
    SFTP.close(session)
    assert_receive :sftp_peer_closed
  end

  test "a forged session cannot kill an unrelated process on call timeout" do
    unrelated =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn -> send(unrelated, :done) end)

    fake = %SFTP{
      pid: unrelated,
      ref: make_ref(),
      timeout: 1,
      lifetime: RequestContext.new!(timeout: 1_000)
    }

    assert {:error, %Error{}} = SFTP.extensions(fake)
    assert Process.alive?(unrelated)
    send(unrelated, :done)
    eventually_dead(unrelated)
  end

  defp eventually_dead(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
  end

  defp steps do
    [
      %{Op: "open", Path: "dir/雪+file", Mode: "create"},
      %{Op: "read", Offset: 3, Count: 5},
      %{Op: "write", Offset: 9, Data: Base.encode64(@write)},
      %{Op: "read", Offset: 15, Count: 1},
      %{Op: "close_file"}
    ]
  end

  defp identity(:gen_tcp, _root), do: nil
  defp identity(:ssl, root), do: TLSIdentity.generate(root, "sftp", "localhost")

  defp backend(root, transport, identity, opts \\ []) do
    parent = self()

    common = [
      transport: transport,
      handler: fn request ->
        if request.target == "/1.0" do
          %{
            status: 200,
            body: %{
              type: "sync",
              metadata: %{
                api_version: "1.0",
                api_extensions: Keyword.get(opts, :extensions, ["custom_volume_sftp"])
              }
            }
          }
        else
          %{upgrade: fn transport, socket -> serve(transport, socket, parent, opts) end}
        end
      end
    ]

    endpoint =
      if transport == :gen_tcp,
        do: [path: Path.join(root, "s#{System.unique_integer([:positive])}")],
        else: [
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            verify: :verify_peer,
            fail_if_no_peer_cert: true,
            cacertfile: identity.cafile
          ]
        ]

    start_supervised!({HTTPFixture, common ++ endpoint}, id: make_ref())
  end

  defp serve(transport, socket, parent, opts) do
    version = Keyword.get(opts, :version, version())
    response = frame(version)
    upgrade = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: sftp\r\n\r\n"
    transport.send(socket, upgrade <> if(opts[:coalesced], do: response, else: ""))
    init = receive_packet(transport, socket)
    send(parent, {:sftp_packet, init})

    unless opts[:coalesced] || opts[:stall_version],
      do: send_response(transport, socket, response, opts[:fragmented])

    cond do
      opts[:idle_eof] ->
        send(parent, {:sftp_eof_worker, self()})

        receive do
          :close_idle -> :ok
        end

      opts[:close_after_version] || opts[:stall_version] ->
        wait_peer_close(transport, socket, parent)

      true ->
        commands(transport, socket, parent, opts)
    end
  end

  defp commands(transport, socket, parent, opts) do
    case receive_packet(transport, socket) do
      <<type, id::32, rest::binary>> = packet ->
        send(parent, {:sftp_packet, packet})

        body =
          if opts[:reply] do
            opts[:reply].(type, id, rest)
          else
            default_reply(type, id, rest, opts)
          end

        case body do
          :close ->
            :ok

          :stall ->
            wait_peer_close(transport, socket, parent)

          {:wire, wire} ->
            transport.send(socket, wire)
            wait_peer_close(transport, socket, parent)

          bytes ->
            send_response(transport, socket, frame(bytes), opts[:fragmented])
            commands(transport, socket, parent, opts)
        end

      :closed ->
        send(parent, :sftp_peer_closed)
    end
  end

  defp default_reply(type, id, rest, opts) do
    cond do
      opts[:status] -> status(id, opts[:status], "private-denial")
      type == 3 -> <<102, id::32, string(@handle)::binary>>
      type == 5 -> read_reply(id, rest)
      true -> status(id, 0, "")
    end
  end

  defp read_reply(id, rest) do
    <<_len::32, _handle::binary-size(byte_size(@handle)), offset::64, _count::32>> = rest
    if offset == 15, do: status(id, 1, "EOF"), else: <<103, id::32, string(@read)::binary>>
  end

  defp wait_peer_close(transport, socket, parent) do
    case transport.recv(socket, 0, 3_000) do
      {:error, :closed} -> send(parent, :sftp_peer_closed)
      {:ok, _} -> wait_peer_close(transport, socket, parent)
      {:error, reason} -> send(parent, {:sftp_peer_error, reason})
    end
  end

  defp receive_packet(transport, socket) do
    case transport.recv(socket, 4, 3_000) do
      {:ok, <<length::32>>} ->
        if length == 0, do: <<>>, else: elem(transport.recv(socket, length, 3_000), 1)

      {:error, :closed} ->
        :closed
    end
  end

  defp send_response(transport, socket, response, true) do
    for <<byte <- response>>, do: transport.send(socket, <<byte>>)
  end

  defp send_response(transport, socket, response, _), do: transport.send(socket, response)
  defp frame(body), do: <<byte_size(body)::32, body::binary>>
  defp string(bytes), do: <<byte_size(bytes)::32, bytes::binary>>

  defp version,
    do: <<2, 3::32>> <> Enum.map_join(@ext, fn {name, value} -> string(name) <> string(value) end)

  defp status(id, code, message),
    do: <<101, id::32, code::32, string(message)::binary, string("en")::binary>>

  defp client(fixture, identity, opts \\ []) do
    endpoint = HTTPFixture.endpoint(fixture)

    defaults = [
      owner: :fixture,
      project: "project +",
      member: "member +",
      timeout: 500,
      stream_timeout: 3_000,
      max_chunk_bytes: 132_096
    ]

    connection =
      if endpoint[:socket],
        do: Connection.unix!(endpoint.socket, defaults ++ opts),
        else:
          Connection.https!(
            endpoint.url,
            defaults ++
              opts ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          )

    %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: ["custom_volume_sftp"]}
    }
  end

  defp open(client, :instance), do: Incus.file_sftp(client, "name+/@ é")
  defp open(client, :volume), do: Incus.volume_file_sftp(client, "pool+@ ", "custom", "name+/@ é")

  defp native_input(fixture, identity, kind) do
    endpoint = HTTPFixture.endpoint(fixture)

    input = %{
      Kind: Atom.to_string(kind),
      Name: "name+/@ é",
      Pool: "pool+@ ",
      VolumeType: "custom",
      Project: "project +",
      Target: "member +",
      Extensions: ["future", "posix-rename@openssh.com", "absent"]
    }

    if endpoint[:socket],
      do: Map.put(input, :Socket, endpoint.socket),
      else:
        Map.merge(input, %{
          URL: endpoint.url,
          CA: File.read!(identity.cafile),
          Cert: File.read!(identity.certfile),
          Key: File.read!(identity.keyfile)
        })
  end

  defp packets(acc \\ []) do
    receive do
      {:sftp_packet, packet} -> packets([packet | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp oracle(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} -> collect(port, data <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(data)
      {^port, {:exit_status, status}} -> flunk("SFTP native driver exited #{status}: #{data}")
    after
      6_000 ->
        Port.close(port)
        flunk("SFTP native driver deadline")
    end
  end
end
