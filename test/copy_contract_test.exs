defmodule Opsmaru.Incus.CopyContractTest do
  @moduledoc "S10 copy orchestration compared with the pinned Copy* methods."
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Copy, Error, Migration, Operation, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture}
  @driver Path.expand("../.integration/copy-contract-driver", __DIR__)
  @extensions ~w(storage_api_local_volume_handling storage_api_remote_volume_handling storage_api_volume_snapshots container_push container_push_target container_only_migration container_incremental_copy container_snapshot_stateful_migration virtual-machines)
  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./copycontract"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-s10-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} S10 relay agrees with the pinned client on requests, channels and bytes",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for kind <- [:instance, :snapshot, :volume] do
        # Live instances and stateful snapshots relay the CRIU state channel too.
        channels = channels(kind)
        native = relay_run(root, identity, kind, channels, :pinned)
        local = relay_run(root, identity, kind, channels, :local)

        assert native.result["completed"], inspect(native.result)
        assert local.posts == native.posts
        assert local.sockets == native.sockets
        assert local.frames == native.frames

        # Every channel opened once per side, and each side's bytes reached the other.
        assert native.sockets == %{"source" => channels, "target" => channels}

        assert native.frames ==
                 Enum.sort(
                   for(c <- channels, do: {"source", c, "target:" <> c}) ++
                     for(c <- channels, do: {"target", c, "source:" <> c})
                 )

        assert local.deletes == 0 and native.deletes == 0
      end
    end

    test "#{transport} S10 relay differences from the pinned client are explicit", %{root: root} do
      identity = identity(root, unquote(transport))

      # Approved difference: the pinned client relays when the source offers a superset
      # of the target's channels; the relay here requires identical sets and opens none.
      superset = [source: ~w(control criu fs), target: ~w(control fs)]
      native = relay_run(root, identity, :instance, superset, :pinned)
      assert native.result["completed"], inspect(native.result)
      assert "control" in native.sockets["target"]

      local = relay_run(root, identity, :instance, superset, :local)
      assert {:error, %Error{kind: :invalid_relay, response: %{accepted: accepted}}} = local.relay
      assert accepted.source.url == "/1.0/operations/source"
      assert accepted.target.url == "/1.0/operations/target"
      assert local.sockets == %{"source" => [], "target" => []}

      # Approved difference: a channel that fails to open stops the pinned client's data
      # loop silently; the relay here fails and closes every channel it opened.
      refused = [refuse: "fs"]
      native = relay_run(root, identity, :instance, refused, :pinned)
      assert native.result["completed"], inspect(native.result)
      assert {"target", "control", "source:control"} in native.frames

      local = relay_run(root, identity, :instance, refused, :local)
      assert {:error, %Error{kind: :native, http_status: 403}} = local.relay
      refute Enum.any?(local.frames, fn {_, channel, _} -> channel == "fs" end)
      assert local.deletes == 0
    end

    test "#{transport} S10 lost or malformed copy replies are uncertain and never replayed", %{
      root: root
    } do
      identity = identity(root, unquote(transport))
      modes = if unquote(transport) == :https, do: [:relay, :pull, :push], else: [:relay]

      for kind <- [:instance, :snapshot, :volume], mode <- modes, reply <- [:lost, :malformed] do
        # Pull and relay accept the source first; push accepts the target first.
        {first, second} = if mode == :push, do: {"target", "source"}, else: {"source", "target"}

        # The first request is lost: the second side is never asked.
        {source, target} = pair(root, identity, %{first => reply})

        assert {:error, %Error{kind: :uncertain}} = copy(kind, mode, source, target)
        assert length(posts(side(source, target, first))) == 1
        assert posts(side(source, target, second)) == []

        # The second request is lost: the first accepted handle is kept, not cancelled.
        {source, target} = pair(root, identity, %{second => reply})

        assert {:error, %Error{kind: :uncertain, response: %{accepted: accepted}}} =
                 copy(kind, mode, source, target)

        assert Map.fetch!(accepted, String.to_atom(first)).url == "/1.0/operations/" <> first
        assert is_nil(Map.fetch!(accepted, String.to_atom(second)))

        for name <- [first, second] do
          requests = HTTPFixture.requests(side(source, target, name).fixture)
          assert length(Enum.filter(requests, &(&1.method == "POST"))) == 1
          refute Enum.any?(requests, &(&1.method == "DELETE"))
        end
      end
    end
  end

  test "https S10 remote copy wait and cancel agree with the pinned remote operation", %{
    root: root
  } do
    identity = identity(root, :https)

    for kind <- [:instance, :snapshot, :volume],
        mode <- [:pull, :push],
        outcome <- [:success, :failure, :cancel] do
      {source, target} = pair(root, identity, %{}, outcome)
      native = reference(root, identity, kind, mode, source, target, outcome)
      native_target = HTTPFixture.requests(target.fixture)
      native_source = HTTPFixture.requests(source.fixture)

      {source, target} = pair(root, identity, %{}, outcome)
      assert {:ok, migration} = copy(kind, mode, source, target)
      assert migration.mode == mode

      case outcome do
        :success ->
          assert native["completed"], inspect(native)
          assert {:ok, waited} = Migration.wait_target(migration, timeout: 2_000)
          assert Operation.successful?(waited.target)

        :failure ->
          # The pinned client may wrap the failure as its multi-address attempt result
          # ("Failed instance migration", "Failed storage volume creation"); this
          # client has one approved origin and reports the native error itself.
          assert native["error"] =~ ~r/^(Failed [a-z ]+: )?boom$/

          assert {:error, %Error{response: %{error: %Error{kind: :operation_failed} = error}}} =
                   Migration.wait_target(migration, timeout: 2_000)

          assert Operation.data(%{migration.target | response: error.response})["err"] == "boom"

        :cancel ->
          # The pinned RemoteOperation tracks the operation that drives the copy: the
          # target's in pull mode and the source's migrate operation in push mode.
          # For volumes it tracks none: tryCreateStoragePoolVolume and
          # tryMigrateStoragePoolVolume shadow their result, so CancelTarget has
          # nothing to cancel. Approved difference:
          # cancel_target always cancels the destination; the pinned push
          # cancellation is Operation.cancel/1 on the explicit source handle.
          native_deletes = %{target: native_target, source: native_source}

          driving =
            case {kind, mode} do
              {:volume, _} -> nil
              {_, :pull} -> "target"
              {_, :push} -> "source"
            end

          if driving do
            assert native["canceled"], inspect(native)
            assert [_] = deletes(native_deletes, driving)
            other = if driving == "source", do: "target", else: "source"
            assert deletes(native_deletes, other) == []
          else
            assert native["error"] == "No associated target operation"

            assert deletes(native_deletes, "source") == [] and
                     deletes(native_deletes, "target") == []
          end

          assert {:ok, _} = Migration.cancel_target(migration)
          if mode == :push, do: assert({:ok, _} = Operation.cancel(migration.source))

          local = %{
            target: HTTPFixture.requests(target.fixture),
            source: HTTPFixture.requests(source.fixture)
          }

          # One DELETE on the destination, plus the explicit source cancel in push mode,
          # each the pinned client's request where it sends one.
          assert [target_delete] = deletes(local, "target")
          if driving == "target", do: assert(deletes(native_deletes, "target") == [target_delete])

          case mode do
            :pull -> assert deletes(local, "source") == []
            :push -> assert [_] = deletes(local, "source")
          end

          if driving == "source",
            do: assert(deletes(native_deletes, "source") == deletes(local, "source"))
      end

      # One POST per side, as in the pinned client; nothing is resent.
      for {native, fixture} <- [{native_source, source.fixture}, {native_target, target.fixture}] do
        assert length(Enum.filter(native, &(&1.method == "POST"))) == 1
        assert length(posts(%{fixture: fixture})) == 1
      end
    end
  end

  test "unix S10 pull and push need an approved HTTPS origin before any request", %{root: root} do
    {source, target} = pair(root, nil, %{})

    for kind <- [:instance, :snapshot, :volume], mode <- [:pull, :push] do
      assert {:error, %Error{kind: :unapproved_migration_origin}} =
               copy(kind, mode, source, target)
    end

    assert posts(source) == [] and posts(target) == []
  end

  # A relay run against fresh fixtures, by the pinned client or by Copy.* + relay/2.
  defp relay_run(root, identity, kind, channels, who) do
    {source_channels, target_channels, refuse} =
      case channels do
        [source: source, target: target] -> {source, target, nil}
        [refuse: refused] -> {channels(kind), channels(kind), refused}
        list -> {list, list, nil}
      end

    log = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    # The source closes each channel once the target's frame reached it; the target's
    # operation completes only after the expected frames were relayed, so the pinned
    # client cannot finish before its relay.
    relayed =
      if refuse || match?([source: _, target: _], channels),
        do: 2,
        else: 2 * length(source_channels)

    source = backend(root, identity, "source", source_channels, log, close: true, refuse: refuse)

    target =
      backend(root, identity, "target", target_channels, log,
        await_frames: relayed,
        refuse: refuse
      )

    {result, relay} =
      case who do
        :pinned ->
          {reference(root, identity, kind, :relay, source, target, :success), nil}

        :local ->
          {:ok, migration} = copy(kind, :relay, source, target)
          relay = Migration.relay(migration, timeout: 2_000)

          if match?({:ok, _}, relay),
            do: {:ok, _} = Migration.wait_target(migration, timeout: 2_000)

          {nil, relay}
      end

    %{
      result: result,
      relay: relay,
      posts:
        for(
          side <- [source, target],
          request <- posts(side),
          do: {request.method, request.target, Jason.decode!(request.body)}
        ),
      sockets: %{"source" => sockets(source), "target" => sockets(target)},
      frames: frames(log),
      deletes:
        Enum.count(
          HTTPFixture.requests(source.fixture) ++ HTTPFixture.requests(target.fixture),
          &(&1.method == "DELETE")
        )
    }
  end

  defp channels(:volume), do: ~w(control fs)
  defp channels(_), do: ~w(control criu fs)

  # The channels a side's operation websocket was opened for, by secret.
  defp sockets(side) do
    Enum.sort(
      for request <- HTTPFixture.requests(side.fixture),
          String.ends_with?(URI.parse(request.target).path, "/websocket"),
          secret = URI.decode_query(URI.parse(request.target).query || "")["secret"],
          String.starts_with?(secret, side.name <> "-"),
          do: String.replace_prefix(secret, side.name <> "-", "")
    )
  end

  defp copy(kind, mode, source, target) do
    origin =
      case mode do
        :pull -> source.origin
        :push -> target.origin
        :relay -> nil
      end

    opts = [name: "copied", mode: mode] ++ if(origin, do: [approved_origin: origin], else: [])
    opts = if kind == :volume, do: opts, else: Keyword.put(opts, :live, true)

    case kind do
      :instance ->
        Copy.instance(target.client, source.client, model(kind), opts)

      :snapshot ->
        Copy.snapshot(target.client, source.client, "parent", model(kind), opts)

      :volume ->
        Copy.volume(target.client, source.client, "new-pool", "old-pool", model(kind), opts)
    end
  end

  defp reference(root, identity, kind, mode, source, target, outcome) do
    options = %{Name: "copied", Mode: Atom.to_string(mode)}
    options = if kind == :volume, do: options, else: Map.put(options, :Live, true)

    input = %{
      action: kind,
      after: if(outcome == :cancel, do: "cancel", else: "wait"),
      source: native(source, identity),
      target: native(target, identity),
      body: model(kind),
      options: options,
      pool: "new-pool",
      source_pool: "old-pool",
      parent: "parent"
    }

    file = Path.join(root, "copy-#{System.unique_integer([:positive])}.json")
    File.write!(file, Jason.encode!(input))
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end

  defp native(side, nil), do: %{socket: side.endpoint.socket, project: "fixture"}

  defp native(side, identity),
    do: %{
      url: side.endpoint.url,
      tls_ca: File.read!(identity.cafile),
      client_cert: File.read!(identity.certfile),
      client_key: File.read!(identity.keyfile),
      project: "fixture"
    }

  # Source and target backends whose POST replies may be lost or malformed.
  defp pair(root, identity, replies, outcome \\ :success) do
    log = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    sides =
      for name <- ["source", "target"],
          do:
            backend(root, identity, name, ~w(control fs), log,
              reply: Map.get(replies, name, :accept),
              outcome: outcome
            )

    List.to_tuple(sides)
  end

  # The DELETE requests a side received, by method and target.
  defp deletes(requests, name),
    do:
      for(
        request <- Map.fetch!(requests, String.to_atom(name)),
        request.method == "DELETE",
        do: request.target
      )

  defp side(source, _target, "source"), do: source
  defp side(_source, target, "target"), do: target

  defp posts(side), do: Enum.filter(HTTPFixture.requests(side.fixture), &(&1.method == "POST"))

  # An Incus-shaped backend: discovery, accepted migration POSTs carrying channel
  # secrets, operation channels that exchange one binary frame each way, and the
  # operation's own wait, poll and cancellation.
  defp backend(root, identity, name, channels, log, opts) do
    secrets = Map.new(channels, &{&1, name <> "-" <> &1})
    certificate = if identity, do: File.read!(identity.certfile), else: ""

    side = %{name: name, secrets: secrets, certificate: certificate, log: log, opts: opts}
    handler = &respond(side, &1, URI.parse(&1.target).path)

    options =
      if identity,
        do: [
          transport: :ssl,
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            cacertfile: identity.cafile,
            verify: :verify_peer,
            fail_if_no_peer_cert: true
          ]
        ],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "#{name}-#{System.unique_integer([:positive])}")
        ]

    fixture = start_supervised!({HTTPFixture, options ++ [handler: handler]}, id: make_ref())
    endpoint = HTTPFixture.endpoint(fixture)
    connection_opts = [owner: :fixture, project: "fixture", timeout: 5_000]

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            connection_opts ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, connection_opts)

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{
        api_extensions: @extensions,
        environment: %{"server_name" => name, "certificate" => certificate}
      }
    }

    %{name: name, fixture: fixture, endpoint: endpoint, client: client, origin: endpoint[:url]}
  end

  defp respond(side, _request, "/1.0"),
    do: %{
      status: 200,
      body: %{
        type: "sync",
        metadata: %{
          api_version: "1.0",
          auth: "trusted",
          api_extensions: @extensions,
          environment: %{server_name: side.name, certificate: side.certificate}
        }
      }
    }

  defp respond(side, %{method: "POST"}, _path) do
    case side.opts[:reply] do
      :lost ->
        %{raw: ""}

      :malformed ->
        %{status: 200, body: "malformed"}

      _ ->
        Agent.update(side.log, &[{:posted, side.name} | &1])
        accepted(side.name, side.secrets)
    end
  end

  defp respond(_side, %{method: "DELETE"}, _path),
    do: %{status: 200, body: %{type: "sync", status_code: 200, metadata: %{}}}

  defp respond(side, request, path) do
    if String.ends_with?(path, "/websocket") do
      upgrade(side, request)
    else
      # Only operation waits and polls settle; other reads (a parent instance) answer now.
      if String.starts_with?(path, "/1.0/operations/") do
        deadline = System.monotonic_time(:millisecond) + 3_000
        settle(side.log, side.opts[:await_frames] || 0, deadline)
      end

      %{status: 200, body: %{type: "sync", metadata: operation(side.name, side.opts[:outcome])}}
    end
  end

  # An operation channel opens only for a known, unrefused secret.
  defp upgrade(side, request) do
    secret = URI.decode_query(URI.parse(request.target).query || "")["secret"]
    channel = Enum.find_value(side.secrets, fn {c, s} -> if s == secret, do: c end)

    if channel && channel != side.opts[:refuse],
      do: %{
        upgrade:
          &channel(&1, &2, request, side.name, channel, side.log, side.opts[:close] || false)
      },
      else: %{status: 403, body: %{type: "error", error_code: 403, error: "refused"}}
  end

  defp accepted(name, secrets),
    do: %{
      status: 202,
      body: %{
        type: "async",
        status_code: 100,
        operation: "/1.0/operations/" <> name,
        metadata: %{
          id: name,
          class: "websocket",
          status: "Running",
          status_code: 103,
          may_cancel: true,
          metadata: secrets
        }
      }
    }

  defp operation(name, :failure),
    do: %{id: name, status: "Failure", status_code: 400, err: "boom", may_cancel: false}

  defp operation(name, :cancel),
    do: %{id: name, status: "Running", status_code: 103, err: "", may_cancel: true}

  defp operation(name, _),
    do: %{id: name, status: "Success", status_code: 200, err: "", may_cancel: false}

  # An operation answers only once both sides were asked (the pinned push copy issues
  # its source request in the background) and the expected frames were relayed.
  defp settle(log, frames, deadline) do
    posted = Enum.count(Agent.get(log, & &1), &match?({:posted, _}, &1))

    if (posted < 2 or length(frames(log)) < frames) and
         System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      settle(log, frames, deadline)
    end
  end

  defp frames(log), do: Enum.sort(for {_, _, _} = frame <- Agent.get(log, & &1), do: frame)

  # One operation channel: complete the upgrade, send this side's frame and record every
  # frame received. The source closes once the other side's frame arrived (or after a
  # bound, when none comes), so the relay ends.
  defp channel(transport, socket, request, name, channel, log, close) do
    accept = Base.encode64(:crypto.hash(:sha, request.headers["sec-websocket-key"] <> @guid))

    :ok =
      transport.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
        accept,
        "\r\n\r\n",
        WebSocketFixture.frame(2, name <> ":" <> channel)
      ])

    if close do
      spawn(fn ->
        Process.sleep(1_500)
        transport.send(socket, WebSocketFixture.frame(8, <<1000::16>>))
      end)
    end

    receive_frames(transport, socket, name, channel, log, close)
  end

  defp receive_frames(transport, socket, name, channel, log, close) do
    with {:ok, <<_::4, opcode::4, 1::1, length::7>>} <- transport.recv(socket, 2, 3_000),
         true <- length <= 125,
         {:ok, <<mask::binary-size(4), payload::binary-size(length)>>} <-
           transport.recv(socket, 4 + length, 3_000) do
      data = unmask(payload, mask)

      if opcode in [1, 2] do
        Agent.update(log, &[{name, channel, data} | &1])
        if close, do: transport.send(socket, WebSocketFixture.frame(8, <<1000::16>>))
        receive_frames(transport, socket, name, channel, log, false)
      end
    end
  end

  defp unmask(payload, mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  defp model(:instance),
    do: %{
      "name" => "source",
      "type" => "container",
      "status_code" => 103,
      "architecture" => "aarch64",
      "config" => %{"volatile.base_image" => "image"},
      "devices" => %{"root" => %{"type" => "disk", "pool" => "p"}},
      "profiles" => ["default"],
      "ephemeral" => true
    }

  defp model(:snapshot),
    do: %{
      "name" => "parent/snapshot",
      "stateful" => true,
      "config" => %{"volatile.base_image" => "image"},
      "devices" => %{},
      "profiles" => ["default"],
      "ephemeral" => true
    }

  defp model(:volume),
    do: %{
      "name" => "volume",
      "type" => "custom",
      "location" => "none",
      "config" => %{"size" => "10GiB"},
      "description" => "native",
      "content_type" => "block"
    }

  defp identity(_root, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "s10-#{System.unique_integer([:positive])}", "localhost")
end
