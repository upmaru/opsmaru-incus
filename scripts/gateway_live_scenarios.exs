defmodule OpsmaruGatewayLiveScenarios do
  @moduledoc """
  Source-owned, explicitly invoked real-Incus acceptance scenarios.

  Requiring this module does not read config, start a listener or contact Incus.
  Only the reviewed host's verified fresh-project context may invoke run/1.
  """
  alias Opsmaru.Incus
  alias OpsmaruGatewayAcceptance, as: Acceptance
  alias OpsmaruGatewayAcceptance.Host
  alias OpsmaruGatewayDaemonProbe, as: DaemonProbe
  @sides ~w(source target)
  @payload :binary.copy(<<0, 255, 128, 13, 10>>, 16_384)
  @proof_fields ~w(operation status_code http_status error_kind bytes sha256 exit event_operation received_bytes export_bytes read_bytes readonly local_detach remote_cancel accepted)

  def load_config!(path) do
    require!(
      is_binary(path) and Path.type(path) == :absolute,
      "explicit absolute config path required"
    )

    {:ok, file} = File.open(path, [:read, :binary])

    raw =
      try do
        IO.binread(file, 65_537)
      after
        File.close(file)
      end

    require!(is_binary(raw) and byte_size(raw) <= 65_536, "configuration exceeds 64 KiB")
    raw |> Jason.decode!(objects: :ordered_objects) |> unique_json!(0)
  end

  defp unique_json!(%Jason.OrderedObject{values: pairs}, depth) when depth < 32 do
    keys = Enum.map(pairs, &elem(&1, 0))
    require!(length(keys) == length(Enum.uniq(keys)), "duplicate configuration field")
    Map.new(pairs, fn {key, value} -> {key, unique_json!(value, depth + 1)} end)
  end

  defp unique_json!(list, depth) when is_list(list) and depth < 32,
    do: Enum.map(list, &unique_json!(&1, depth + 1))

  defp unique_json!(value, depth) when depth < 32 and not is_map(value), do: value
  defp unique_json!(_, _), do: raise("configuration nesting bound")

  def prepare!(config) do
    Acceptance.validate!(config)

    for side <- @sides do
      require!(
        is_binary(config[side]["network"]) and config[side]["network"] != "",
        "explicit verified network required"
      )

      validate_direct_backend!(config[side]["backend"])
    end

    verify_cli_provenance!(config["incus_cli"], config["incus_cli_provenance"])
    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: Path.expand("..", __DIR__))
    require!(status == "", "committed clean acceptance source required")

    prepared =
      config["state_directory"] <>
        "-prepared-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    File.mkdir!(prepared)
    File.chmod!(prepared, 0o700)
    driver = build_driver(%{runtime: prepared})

    config
    |> Map.put("native_driver", driver)
    |> Map.put("native_driver_sha256", digest(File.read!(driver)))
  end

  def run(context) do
    require!(
      Regex.match?(~r/\Agw-[0-9a-f]{12}-\z/, context.resource_prefix),
      "verified run prefix required"
    )

    cli = context.config["incus_cli"]

    require!(
      is_binary(cli) and Path.type(cli) == :absolute and File.regular?(cli),
      "explicit native CLI required"
    )

    verify_cli_provenance!(cli, context.config["incus_cli_provenance"])
    configure_cli(context)
    driver = context.config["native_driver"]

    require!(
      is_binary(driver) and File.regular?(driver) and
        digest(File.read!(driver)) == context.config["native_driver_sha256"],
      "preflight native driver required"
    )

    context = Map.merge(context, %{native_driver: driver, native_cli: cli})

    Acceptance.record_detail(context, "native-tool-provenance", %{
      "cli_sha256" => digest(File.read!(cli)),
      "driver_sha256" => digest(File.read!(driver)),
      "source_revision" => source_revision(),
      "tool_sha256" => digest(File.read!(context.config["incus_cli_provenance"]))
    })

    Acceptance.record_detail(context, "native-scenario-source", %{
      "hashes" => %{
        "scenario" => digest(File.read!(__ENV__.file)),
        "driver_source" =>
          digest(File.read!(Path.expand("../test/reference/gatewaylive/main.go", __DIR__)))
      }
    })

    discovery_and_enrollment(context)
    base = context.resource_prefix <> "base"
    create_base(context, base)
    checked_cli(context, "start-owned-base", ["start", "source:" <> base, "--quiet"])
    ready_instance(context, base, 30)
    probe_guest(context, base)
    daemon_peers = DaemonProbe.verify_and_activate(context)
    http_and_protocols(context, base)
    denial(context, base)
    interruption(context, base)

    seed =
      driver(context, "source", "binary", %{
        "Name" => base,
        "Path" => "/tmp/opsmaru-gateway-migration-canary",
        "Data" => Base.encode64(@payload),
        "Keep" => true
      })

    require!(
      seed["passed"] and seed["sha256"] == digest(@payload),
      "migration binary canary seed failed"
    )

    checked_cli(context, "stop-owned-base", [
      "stop",
      "source:" <> base,
      "--timeout",
      "30",
      "--quiet"
    ])

    migration(context, base, daemon_peers)
    cases = Agent.get(context.journal, & &1["cases"])
    if Acceptance.evidence_complete?(cases), do: cleanup_owned(context)
    :ok
  end

  defp configure_cli(context) do
    root = context.incus_conf
    for directory <- ~w(servercerts clientcerts), do: File.mkdir!(Path.join(root, directory))

    remotes =
      for side <- @sides do
        spec = context.config[side]
        gateway = spec["gateway"]
        copy_private(gateway["server_certificate"], Path.join(root, "servercerts/#{side}.crt"))
        copy_private(gateway["client_certificate"], Path.join(root, "clientcerts/#{side}.crt"))
        copy_private(gateway["client_key"], Path.join(root, "clientcerts/#{side}.key"))

        "  #{side}:\n    addr: #{Jason.encode!(gateway["https"])}\n    auth_type: tls\n    project: #{Jason.encode!(spec["project"])}\n"
      end

    File.write!(Path.join(root, "config.yml"), [
      "config: {}\nremotes:\n",
      remotes,
      "default-remote: source\n"
    ])

    File.chmod!(Path.join(root, "config.yml"), 0o600)
  end

  defp build_driver(context) do
    path = Path.join(context.runtime, "gateway-live-native")
    reference = Path.expand("../test/reference", __DIR__)

    env = [
      {"GOTOOLCHAIN", "local"},
      {"GOFLAGS", ""},
      {"GOWORK", "off"},
      {"GOENV", "off"},
      {"CGO_ENABLED", "0"}
    ]

    {_, 0} =
      System.cmd("mise", ["exec", "--", "go", "mod", "verify"],
        cd: reference,
        env: env,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "mise",
        ["exec", "--", "go", "build", "-mod=readonly", "-o", path, "./gatewaylive"],
        cd: reference,
        env: env,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd("mise", ["exec", "--", "go", "mod", "verify"],
        cd: reference,
        env: env,
        stderr_to_stdout: true
      )

    path
  end

  defp discovery_and_enrollment(context) do
    for side <- @sides do
      # Only this explicitly created fixture's ephemeral trust is reset.
      # Incus/backend trust is never changed by gateway enrollment tests.
      Agent.update(context.sides[side].host.state, &%{&1 | trust: %{}})
      discovery = driver(context, side, "discovery", %{}, authenticated: false)

      require!(
        discovery["passed"] and discovery["auth"] == "untrusted" and
          discovery["api_version"] == "1.0",
        "anonymous discovery mismatch"
      )
    end

    Acceptance.record_case(context, "discovery", "passed")

    for side <- @sides do
      before = driver(context, side, "discovery", %{})
      require!(before["auth"] == "untrusted", "enrollment peer was already trusted")

      denied =
        driver(context, side, "enrollment", %{"Token" => "invalid-test-token"},
          expected_status: 403
        )

      require!(denied["http_status"] == 403, "wrong enrollment token was accepted")
      result = driver(context, side, "enrollment", %{"Token" => context.sides[side].token})
      require!(result["passed"] and result["auth"] == "trusted", "host enrollment failed")
      trusted = Agent.get(context.sides[side].host.state, & &1.trust)
      Agent.update(context.sides[side].host.state, &%{&1 | trust: %{}})

      replay =
        driver(context, side, "enrollment", %{"Token" => context.sides[side].token},
          expected_status: 403
        )

      require!(replay["http_status"] == 403, "single-use enrollment token was replayed")
      # Restore exactly the grant obtained by the successful native enrollment.
      Agent.update(context.sides[side].host.state, &%{&1 | trust: trusted})
    end

    Acceptance.record_case(context, "enrollment", "passed")
  end

  defp create_base(context, name) do
    spec = context.config["source"]

    require!(
      is_binary(spec["network"]) and spec["network"] != "",
      "explicit verified network required"
    )

    body = %{
      "name" => name,
      "type" => "container",
      "profiles" => [],
      "source" => %{"type" => "image", "fingerprint" => spec["image"]},
      "config" => %{
        "limits.cpu" => "1",
        "limits.memory" => "256MiB",
        "user.opsmaru.acceptance.marker" => context.marker
      },
      "devices" => %{
        "root" => %{"type" => "disk", "path" => "/", "pool" => spec["pool"], "size" => "2GiB"},
        "eth0" => %{"type" => "nic", "network" => spec["network"], "name" => "eth0"}
      }
    }

    native_mutation(context, "source", "create-owned-base", "POST", "/1.0/instances", body)
  end

  defp ready_instance(context, name, attempts) when attempts > 0 do
    {:ok, result} =
      Incus.raw_query(
        context.sides["source"].client,
        "GET",
        "/1.0/instances/#{escape(name)}/state"
      )

    addresses = get_in(result.metadata, ["network", "eth0", "addresses"]) || []

    if result.metadata["status_code"] == 103 and
         Enum.any?(addresses, &(&1["family"] == "inet" and &1["scope"] == "global")) do
      :ok
    else
      Process.sleep(1_000)
      ready_instance(context, name, attempts - 1)
    end
  end

  defp ready_instance(_, _, 0), do: raise("owned container did not become ready")

  defp http_and_protocols(context, name) do
    result = driver(context, "source", "http", %{"Name" => name})
    require!(result["passed"] and result["name"] == name, "native HTTP instance mismatch")
    Acceptance.record_case(context, "http", "passed")

    binary =
      driver(context, "source", "binary", %{
        "Name" => name,
        "Path" => "/tmp/opsmaru-gateway-binary",
        "Data" => Base.encode64(@payload)
      })

    require!(
      binary["passed"] and binary["sha256"] == digest(@payload),
      "native binary transfer failed"
    )

    Acceptance.record_case(context, "binary", "passed")

    for action <- ~w(exec events) do
      result = driver(context, "source", action, %{"Name" => name})
      require!(result["passed"] and result["exit"] == 7, "native exec/event verification failed")

      if action == "events",
        do: require!(result["event_operation"] == result["operation"], "event identity mismatch")

      Acceptance.record_case(context, action, "passed")
    end

    console = driver(context, "source", "console", %{"Name" => name})

    require!(
      console["passed"] and console["received_bytes"] > 0,
      "native console data/control failed"
    )

    Acceptance.record_case(context, "console", "passed")

    fs_volume = context.resource_prefix <> "files"
    block_volume = context.resource_prefix <> "block"
    pool = context.config["source"]["pool"]

    for {volume, content} <- [{fs_volume, "filesystem"}, {block_volume, "block"}] do
      native_mutation(
        context,
        "source",
        "create-owned-#{content}-volume",
        "POST",
        "/1.0/storage-pools/#{escape(pool)}/volumes/custom",
        %{
          "name" => volume,
          "type" => "custom",
          "content_type" => content,
          "description" => context.marker,
          "config" => %{"size" => "64MiB"}
        }
      )
    end

    for {action, path} <- [
          {"sftp_instance", "/tmp/opsmaru-gateway-sftp"},
          {"sftp_volume", "opsmaru-gateway-sftp"}
        ] do
      result =
        driver(context, "source", action, %{
          "Name" => name,
          "Pool" => pool,
          "Volume" => fs_volume,
          "Path" => path,
          "Data" => Base.encode64(@payload)
        })

      require!(
        result["passed"] and result["sha256"] == digest(@payload),
        "native SFTP binary session failed"
      )
    end

    Acceptance.record_case(context, "sftp", "passed")

    nbd(context, name, pool, block_volume)
  end

  defp nbd(context, name, pool, block_volume) do
    instance_nbd =
      driver(context, "source", "nbd_instance", %{"Name" => name}, expected_status: 400)

    direct =
      driver(context, "source", "nbd_instance", %{"Name" => name},
        direct: true,
        expected_status: 400
      )

    require!(
      instance_nbd["http_status"] == 400 and direct["http_status"] == 400,
      "container NBD must preserve native VM-only rejection"
    )

    Acceptance.record_detail(context, "instance-nbd-native-prerequisite", %{
      "http_status" => 400,
      "native_status" => "VM-only; positive VM case unrun, no VM provisioned"
    })

    volume_nbd =
      driver(context, "source", "nbd_volume", %{
        "Name" => name,
        "Pool" => pool,
        "Volume" => block_volume
      })

    require!(
      volume_nbd["passed"] and volume_nbd["readonly"] and volume_nbd["read_bytes"] == 512,
      "native read-only block-volume NBD failed"
    )

    Acceptance.record_case(context, "nbd", "passed")
  end

  defp denial(context, name) do
    before_count = length(Host.requests(context.sides["source"].host))

    anonymous =
      driver(context, "source", "deny_http", %{}, authenticated: false, expected_status: 403)

    wrong_project =
      driver(context, "source", "deny_http", %{"Project" => "default"}, expected_status: 403)

    raw =
      driver(context, "source", "nbd_instance", %{"Name" => name},
        authenticated: false,
        expected_status: 403
      )

    websocket =
      driver(context, "source", "deny_ws", %{}, authenticated: false, expect_native_error: true)

    require!(
      anonymous["http_status"] == 403 and wrong_project["http_status"] == 403 and
        raw["http_status"] == 403 and websocket["http_status"] == 403,
      "native denial mismatch"
    )

    # Discovery is synthetic; no authenticated request is admitted in these paths.
    require!(
      length(Host.requests(context.sides["source"].host)) == before_count,
      "denied request reached admitted backend path"
    )

    Acceptance.record_case(context, "denial", "passed")
  end

  defp interruption(context, name) do
    counter_path = "/tmp/opsmaru-gateway-interruption-" <> context.marker

    initial =
      driver(context, "source", "readfile", %{"Name" => name, "Path" => counter_path},
        expected_status: 404
      )

    require!(initial["http_status"] == 404, "interruption counter must initially be absent")
    Acceptance.record_detail(context, "interruption-initial-state", %{"initial_writes" => 0})
    before_requests = Host.requests(context.sides["source"].host)

    input =
      driver_input(context, "source", "interrupt", %{"Name" => name, "Path" => counter_path}, [])

    path = private_input(context, input)

    port =
      Port.open({:spawn_executable, context.native_driver}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: [path]
      ])

    accepted =
      try do
        accepted = await_json(port, "", System.monotonic_time(:millisecond) + 45_000)

        require!(
          accepted["accepted"] and is_binary(accepted["operation"]),
          "accepted exec identity required before loss"
        )

        Acceptance.record_detail(context, "interruption-accepted-before-frontend-loss", %{
          "operation" => accepted["operation"],
          "accepted" => true
        })

        terminate_owned(port)
        accepted
      after
        if Port.info(port) != nil, do: terminate_owned(port)
        File.rm!(path)
      end

    reconciled = driver(context, "source", "wait", %{"Operation" => accepted["operation"]})

    require!(
      reconciled["passed"] and reconciled["operation"] == accepted["operation"] and
        reconciled["status_code"] >= 200,
      "native interruption reconciliation unavailable"
    )

    proof =
      driver(
        context,
        "source",
        "readfile",
        %{"Name" => name, "Path" => counter_path},
        expected_status: 404
      )

    # Incus may itself end an exec when its channels close. Reconcile that
    # native outcome without requiring continued remote execution or replay.
    writes =
      cond do
        proof["http_status"] == 404 -> 0
        proof["passed"] and proof["data"] == Base.encode64("x") -> 1
        true -> raise "interrupted mutation proof unavailable or replayed"
      end

    requests = Enum.drop(Host.requests(context.sides["source"].host), length(before_requests))

    posts =
      Enum.count(requests, &(&1.method == "POST" and &1.path == "/1.0/instances/#{name}/exec"))

    deletes = Enum.count(requests, &(&1.method == "DELETE"))
    require!(posts == 1 and deletes == 0, "frontend loss replayed or cancelled native work")

    Acceptance.record_detail(context, "interruption-reconciled", %{
      "operation" => accepted["operation"],
      "gateway_posts" => posts,
      "gateway_deletes" => deletes,
      "final_writes" => writes,
      "native_status" => reconciled["status_code"]
    })

    Acceptance.record_case(context, "interruption", "passed")
  end

  defp probe_guest(context, name) do
    hostname = URI.parse(context.sides["source"].origin).host
    {listener, port} = start_probe()
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    owner = self()
    worker = spawn(fn -> serve_probe(listener, nonce, owner, 2) end)

    try do
      first = probe(context, name, hostname, port, nonce)

      received =
        receive do
          {:gateway_probe, ^nonce, peer} -> peer
        after
          1_000 -> nil
        end

      if first["exit"] == 0 and received != nil do
        Acceptance.record_detail(context, "guest-container-host-diagnostic", %{
          "proof" => %{
            "hostname_reachable" => true,
            "container_peer" => :inet.ntoa(received) |> List.to_string(),
            "nonce_sha256" => digest(nonce),
            "grants_migration_authority" => false
          }
        })

        true
      else
        candidate = context.config["probe_address"]

        if is_binary(candidate) do
          diagnostic = probe(context, name, candidate, port, nonce)

          observed =
            receive do
              {:gateway_probe, ^nonce, peer} -> :inet.ntoa(peer) |> List.to_string()
            after
              1_000 -> nil
            end

          Acceptance.record_detail(context, "guest-address-diagnostic-only", %{
            "proof" => %{
              "candidate" => candidate,
              "reachable" => diagnostic["exit"] == 0,
              "observed_peer" => observed,
              "migration_origin_unchanged" => true
            }
          })
        end

        Acceptance.record_detail(context, "container-origin-diagnostic-unavailable", %{
          "native_status" =>
            "configured gateway FQDN unavailable from owned container; diagnostic only"
        })

        false
      end
    after
      :gen_tcp.close(listener)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end
  end

  defp probe(context, name, host, port, nonce) do
    driver(context, "source", "probe", %{
      "Name" => name,
      "ProbeHost" => host,
      "ProbePort" => port,
      "ProbeURL" => "http://#{host}:#{port}/#{nonce}"
    })
  end

  defp start_probe do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {0, 0, 0, 0}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp serve_probe(_, _, _, 0), do: :ok

  defp serve_probe(listener, nonce, owner, remaining) do
    with {:ok, socket} <- :gen_tcp.accept(listener, 15_000) do
      with {:ok, request} <- :gen_tcp.recv(socket, 0, 4_000),
           true <-
             byte_size(request) <= 4_096 and String.starts_with?(request, "GET /#{nonce} HTTP/1."),
           {:ok, {peer, _}} <- :inet.peername(socket) do
        send(owner, {:gateway_probe, nonce, peer})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n"
        )
      end

      :gen_tcp.close(socket)
      serve_probe(listener, nonce, owner, remaining - 1)
    end
  end

  defp migration(context, base, daemon_peers) do
    for item <- matrix(), do: migration_case(context, base, daemon_peers, item)
  end

  defp migration_case(context, base, daemon_peers, {action, kind, mode, orientation, index}) do
    label = Enum.join([action, kind, mode, orientation], "/")
    limitation = action == "move" and kind == "snapshot"

    to = if orientation == "source", do: "target", else: "source"
    available = migration_peer_available?(daemon_peers, mode, orientation, to)

    if not available and not limitation do
      Acceptance.record_case(context, label, "unrun")
    else
      setup = setup_migration(context, base, kind, orientation, index)

      migration =
        Map.merge(setup, %{
          action: action,
          kind: kind,
          mode: mode,
          label: label,
          limitation: limitation
        })

      before_requests = requests(context)

      Acceptance.record_detail(context, label <> "/intent", %{
        "scenario" => label,
        "proof" => %{
          "source_project" => context.config[setup.from]["project"],
          "source" => setup.resource,
          "target_project" => context.config[setup.to]["project"],
          "target" => setup.destination
        }
      })

      result = migration_cli(context, migration, before_requests)
      verify_migration(context, migration, result, before_requests)
    end
  end

  @doc false
  def migration_peer_available?(_, "relay", _, _), do: true
  def migration_peer_available?(peers, "pull", source, _), do: Map.get(peers, source) == true
  def migration_peer_available?(peers, "push", _, target), do: Map.get(peers, target) == true
  def migration_peer_available?(_, _, _, _), do: false

  defp setup_migration(context, base, kind, from, index) do
    to = if from == "source", do: "target", else: "source"
    name = context.resource_prefix <> "m#{index}"
    destination = context.resource_prefix <> "d#{index}"

    checked_cli(context, "setup-#{index}", [
      "copy",
      "source:#{base}",
      "#{from}:#{name}",
      "--mode",
      "relay",
      "--quiet"
    ])

    resource = if kind == "snapshot", do: name <> "/snapshot", else: name

    if kind == "snapshot",
      do:
        checked_cli(context, "snapshot-#{index}", [
          "snapshot",
          "create",
          "#{from}:#{name}",
          "snapshot"
        ])

    %{from: from, to: to, name: name, destination: destination, resource: resource}
  end

  defp migration_cli(context, migration, before_requests) do
    {:ok, output} =
      Acceptance.step(context, migration.label <> "/cli", fn ->
        result =
          cli(context, [
            migration.action,
            "#{migration.from}:#{migration.resource}",
            "#{migration.to}:#{migration.destination}",
            "--mode",
            migration.mode,
            "--quiet"
          ])

        if expected_migration?(context, migration, result, before_requests),
          do: {:ok, result},
          else: {:error, %Opsmaru.Incus.Error{kind: :native_cli_failed}}
      end)

    output
  after
    record_migration_requests(context, migration.label, before_requests)
  end

  defp expected_migration?(context, %{limitation: true}, result, before_requests),
    do:
      result.status != 0 and result.output =~ "Invalid instance name" and
        mutation_count(context, before_requests) == 0

  defp expected_migration?(_, _, result, _), do: result.status == 0

  defp record_migration_requests(context, label, before_requests) do
    observed =
      for side <- @sides,
          request <- Enum.drop(Host.requests(context.sides[side].host), before_requests[side]),
          do: request

    operations = observed |> Enum.map(& &1.operation) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Acceptance.record_detail(context, label <> "/observed", %{
      "operation_ids" => operations,
      "gateway_posts" => Enum.count(observed, &(&1.method == "POST")),
      "gateway_deletes" => Enum.count(observed, &(&1.method == "DELETE"))
    })
  end

  defp verify_migration(context, %{limitation: true} = migration, result, before_requests) do
    require!(
      expected_migration?(context, migration, result, before_requests),
      "native snapshot move limitation changed"
    )

    Acceptance.record_case(context, migration.label, "native_limitation")

    Acceptance.record_detail(context, migration.label, %{
      "outcome" => "native_limitation",
      "http_status" => 400,
      "retained_source" => true,
      "gateway_posts" => 0,
      "gateway_deletes" => 0
    })
  end

  defp verify_migration(context, migration, result, _) do
    require!(result.status == 0, "native CLI migration failed; resources retained")
    sha256 = verify_destination(context, migration.to, migration.destination)

    if migration.action == "move",
      do:
        require!(
          absent?(context.sides[migration.from].client, migration.name),
          "move source was retained"
        )

    Acceptance.record_case(context, migration.label, "passed")

    Acceptance.record_detail(context, migration.label, %{
      "outcome" => "passed",
      "completed" => true,
      "retained_source" => migration.action != "move",
      "sha256" => sha256,
      "expected_sha256" => digest(@payload)
    })
  end

  def matrix do
    for action <- ~w(copy move),
        kind <- ~w(instance snapshot),
        mode <- ~w(relay pull push),
        orientation <- @sides do
      {action, kind, mode, orientation}
    end
    |> Enum.with_index()
    |> Enum.map(fn {{action, kind, mode, side}, index} -> {action, kind, mode, side, index} end)
  end

  defp verify_destination(context, side, name) do
    {:ok, response} =
      Incus.raw_query(context.sides[side].client, "GET", "/1.0/instances/#{escape(name)}")

    require!(
      response.metadata["name"] == name and
        get_in(response.metadata, ["config", "user.opsmaru.acceptance.marker"]) == context.marker,
      "destination ownership mismatch"
    )

    canary =
      driver(context, side, "readfile", %{
        "Name" => name,
        "Path" => "/tmp/opsmaru-gateway-migration-canary"
      })

    require!(
      canary["passed"] and canary["sha256"] == digest(@payload),
      "migrated binary filesystem data mismatch"
    )

    canary["sha256"]
  end

  defp absent?(client, name),
    do:
      match?(
        {:error, %{http_status: 404}},
        Incus.raw_query(client, "GET", "/1.0/instances/#{escape(name)}")
      )

  defp requests(context),
    do: Map.new(@sides, &{&1, length(Host.requests(context.sides[&1].host))})

  defp mutation_count(context, before) do
    Enum.sum(
      for side <- @sides,
          do:
            Enum.count(
              Enum.drop(Host.requests(context.sides[side].host), before[side]),
              &(&1.method in ["POST", "PUT", "PATCH", "DELETE"])
            )
    )
  end

  defp native_mutation(context, side, label, method, path, body) do
    {:ok, response} =
      Acceptance.step(context, label, fn ->
        Incus.raw_query(context.sides[side].client, method, path, body: body)
      end)

    if path = operation_path!(response) do
      poll_operation(
        context,
        side,
        label,
        path,
        System.monotonic_time(:millisecond) + 120_000
      )
    end

    response
  end

  @doc false
  def operation_path!(%Opsmaru.Incus.Response{type: "sync"}), do: nil

  def operation_path!(%Opsmaru.Incus.Response{type: "async", operation: operation})
      when is_binary(operation) do
    uri = URI.parse(operation)

    require!(
      uri.scheme == nil and uri.host == nil and is_binary(uri.path) and
        Regex.match?(~r/\A\/1\.0\/operations\/[a-zA-Z0-9-]{1,128}\z/, uri.path),
      "native asynchronous operation identity unavailable"
    )

    uri.path
  end

  def operation_path!(_), do: raise("native operation response unavailable")

  defp poll_operation(context, side, label, path, deadline) do
    require!(
      System.monotonic_time(:millisecond) < deadline,
      "native operation deadline; resources retained"
    )

    {:ok, response} =
      Acceptance.step(context, label <> "/poll", fn ->
        Incus.raw_query(context.sides[side].client, "GET", path)
      end)

    status = response.metadata["status_code"]

    if status >= 200 do
      require!(
        status == 200 and response.metadata["err"] in [nil, ""],
        "native operation failed; resources retained"
      )
    else
      Process.sleep(250)
      poll_operation(context, side, label, path, deadline)
    end
  end

  @doc false
  def cleanup_owned(context) do
    require!(
      Acceptance.evidence_complete?(Agent.get(context.journal, & &1["cases"])),
      "partial acceptance cannot be cleaned"
    )

    # Inventory BOTH marked projects before deleting any backend resource.
    inventories =
      for side <- @sides, into: %{} do
        client = context.sides[side].client
        project = context.config[side]["project"]

        {:ok, p} =
          Incus.raw_query(context.clients[side], "GET", "/1.0/projects/#{escape(project)}")

        {:ok, i} = Incus.raw_query(client, "GET", "/1.0/instances?recursion=1")
        pool = escape(context.config[side]["pool"])

        {:ok, v} =
          Incus.raw_query(client, "GET", "/1.0/storage-pools/#{pool}/volumes/custom?recursion=1")

        {:ok, profiles} = Incus.raw_query(client, "GET", "/1.0/profiles?recursion=1")

        snapshots =
          for instance <- i.metadata, into: %{} do
            name = instance["name"]

            {:ok, result} =
              Incus.raw_query(
                client,
                "GET",
                "/1.0/instances/#{escape(name)}/snapshots?recursion=1"
              )

            {name, result.metadata}
          end

        inventory = %{
          project: p.metadata,
          instances: i.metadata,
          volumes: volume_inventory(client, pool, v.metadata),
          profiles: profiles.metadata,
          snapshots: snapshots
        }

        validate_owned_inventory!(inventory, context.resource_prefix, context.marker)
        {side, inventory}
      end

    for side <- @sides do
      inventory = inventories[side]

      for instance <- inventory.instances do
        cleanup_guard!(context, side, :instance, instance["name"])

        native_mutation(
          context,
          side,
          "cleanup-instance/" <> instance["name"],
          "DELETE",
          "/1.0/instances/#{escape(instance["name"])}",
          nil
        )
      end

      pool = escape(context.config[side]["pool"])

      for volume <- inventory.volumes do
        cleanup_guard!(context, side, :volume, volume["name"])

        native_mutation(
          context,
          side,
          "cleanup-volume/" <> volume["name"],
          "DELETE",
          "/1.0/storage-pools/#{pool}/volumes/custom/#{escape(volume["name"])}",
          nil
        )
      end

      for profile <- inventory.profiles do
        # Incus forbids deleting "default" in every project. Revalidate the
        # owned empty profile, then let native project deletion cascade it.
        cleanup_guard!(context, side, :profile, profile["name"])
      end

      project = context.config[side]["project"]

      {:ok, current} =
        Incus.raw_query(context.clients[side], "GET", "/1.0/projects/#{escape(project)}")

      validate_project!(current.metadata, context.marker)

      Acceptance.step(context, "cleanup-project/" <> side, fn ->
        Incus.raw_query(context.clients[side], "DELETE", "/1.0/projects/#{escape(project)}")
      end)
    end

    Acceptance.mark_cleaned(context)
  end

  @doc false
  def validate_owned_inventory!(inventory, prefix, marker) do
    validate_project!(inventory.project, marker)

    for instance <- inventory.instances do
      require!(
        String.starts_with?(instance["name"], prefix) and
          get_in(instance, ["config", "user.opsmaru.acceptance.marker"]) == marker and
          instance["status_code"] == 102,
        "cleanup instance ownership/state mismatch"
      )

      for snapshot <- inventory.snapshots[instance["name"]] do
        require!(
          get_in(snapshot, ["config", "user.opsmaru.acceptance.marker"]) == marker,
          "cleanup snapshot marker mismatch"
        )
      end
    end

    for volume <- inventory.volumes,
        do:
          require!(
            String.starts_with?(volume["name"], prefix) and volume["description"] == marker and
              Map.get(volume, "snapshots", []) == [],
            "cleanup volume ownership mismatch"
          )

    for profile <- inventory.profiles,
        do:
          require!(
            profile["name"] == "default" and profile["config"] == %{} and
              profile["devices"] == %{},
            "cleanup profile is not the owned empty default"
          )

    :ok
  end

  defp validate_project!(project, marker) do
    require!(
      project["description"] == "Opsmaru gateway acceptance " <> marker and
        get_in(project, ["config", "features.profiles"]) == "true" and
        get_in(project, ["config", "features.storage.volumes"]) == "true",
      "cleanup project identity/features changed"
    )
  end

  defp volume_inventory(client, pool, volumes) do
    for volume <- volumes do
      {:ok, response} =
        Incus.raw_query(
          client,
          "GET",
          "/1.0/storage-pools/#{pool}/volumes/custom/#{escape(volume["name"])}/snapshots?recursion=1"
        )

      Map.put(volume, "snapshots", response.metadata)
    end
  end

  defp cleanup_guard!(context, side, kind, name) do
    project = context.config[side]["project"]

    {:ok, current} =
      Incus.raw_query(context.clients[side], "GET", "/1.0/projects/#{escape(project)}")

    validate_project!(current.metadata, context.marker)

    path =
      case kind do
        :instance ->
          "/1.0/instances/#{escape(name)}"

        :volume ->
          "/1.0/storage-pools/#{escape(context.config[side]["pool"])}/volumes/custom/#{escape(name)}"

        :profile ->
          "/1.0/profiles/#{escape(name)}"
      end

    {:ok, resource} = Incus.raw_query(context.sides[side].client, "GET", path)

    snapshots =
      if kind == :instance do
        {:ok, result} =
          Incus.raw_query(context.sides[side].client, "GET", path <> "/snapshots?recursion=1")

        %{name => result.metadata}
      else
        %{}
      end

    validate_owned_inventory!(
      %{
        project: current.metadata,
        instances: if(kind == :instance, do: [resource.metadata], else: []),
        volumes:
          if(kind == :volume,
            do:
              volume_inventory(context.sides[side].client, escape(context.config[side]["pool"]), [
                resource.metadata
              ]),
            else: []
          ),
        profiles: if(kind == :profile, do: [resource.metadata], else: []),
        snapshots: snapshots
      },
      context.resource_prefix,
      context.marker
    )
  end

  @doc false
  def verify_cli_provenance!(cli, reference) do
    require!(
      is_binary(cli) and Path.type(cli) == :absolute and File.regular?(cli),
      "explicit native CLI required"
    )

    require!(
      is_binary(reference) and Path.type(reference) == :absolute and File.regular?(reference),
      "explicit CLI provenance required"
    )

    manifest = load_config!(reference)
    pin = File.read!(Path.expand("../priv/incus/reference.json", __DIR__)) |> Jason.decode!()
    module_line = pin["module"] <> " " <> pin["tag"] <> " " <> (manifest["module_sum"] || "")
    sums = File.read!(Path.expand("../test/reference/go.sum", __DIR__)) |> String.split("\n")

    require!(
      pinned_cli?(manifest, pin) and
        manifest["binary_sha256"] == digest(File.read!(cli)) and module_line in sums and
        ("go" <> pin["go"]) in String.split(manifest["go"] || ""),
      "CLI binary does not match pinned verified provenance"
    )

    :ok
  end

  defp pinned_cli?(manifest, pin),
    do:
      manifest["revision"] == pin["revision"] and manifest["tag"] == pin["tag"] and
        manifest["source_modified"] == false and manifest["version"] == "7.0.1"

  defp driver(context, side, action, arguments, opts \\ []) do
    input = driver_input(context, side, action, arguments, opts)
    path = private_input(context, input)

    try do
      {:ok, decoded} =
        Acceptance.step(context, "native/#{side}/#{action}", fn ->
          result = command(context.native_driver, [path], [], 55_000)
          require!(result.status == 0, "native verifier process failed")
          decoded = Jason.decode!(result.output)
          Acceptance.record_detail(context, "native/#{side}/#{action}", safe_proof(decoded))

          expected = expected_driver_result?(decoded, opts)

          if expected,
            do: {:ok, decoded},
            else:
              {:error,
               %Opsmaru.Incus.Error{
                 kind: :native_verifier_failed,
                 http_status: decoded["http_status"],
                 operation: decoded["operation"]
               }}
        end)

      decoded
    after
      File.rm!(path)
    end
  end

  @doc false
  def expected_driver_result?(decoded, opts) do
    decoded["passed"] == true or
      (opts[:expected_status] != nil and decoded["http_status"] == opts[:expected_status]) or
      (opts[:expect_native_error] == true and is_binary(decoded["error"]))
  end

  @doc false
  def driver_input(context, side, action, arguments, opts) do
    spec = context.config[side]
    input = %{"Action" => action, "Project" => spec["project"]}

    input =
      if opts[:direct] do
        Map.merge(input, direct_backend_input(spec["backend"]))
      else
        gateway = spec["gateway"]

        input =
          Map.merge(input, %{
            "URL" => gateway["https"],
            "ServerCert" => File.read!(gateway["server_certificate"])
          })

        if Keyword.get(opts, :authenticated, true),
          do:
            Map.merge(input, %{
              "ClientCert" => File.read!(gateway["client_certificate"]),
              "ClientKey" => File.read!(gateway["client_key"])
            }),
          else: input
      end

    Map.merge(input, arguments)
  end

  @doc false
  def validate_direct_backend!(backend) when is_map(backend) do
    case {Map.has_key?(backend, "socket"), Map.has_key?(backend, "https")} do
      {true, false} ->
        require!(
          is_binary(backend["socket"]) and Path.type(backend["socket"]) == :absolute,
          "explicit absolute Unix backend required"
        )

      {false, true} ->
        validate_backend_https!(backend)

      _ ->
        raise "one explicit backend transport required"
    end

    :ok
  end

  def validate_direct_backend!(_), do: raise("one explicit backend transport required")

  defp validate_backend_https!(backend) do
    uri = URI.parse(backend["https"] || "")

    require!(
      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and uri.userinfo == nil and
        uri.path in [nil, "", "/"] and uri.query == nil and uri.fragment == nil,
      "explicit HTTPS backend origin required"
    )

    for field <- ~w(server_certificate client_certificate client_key),
        do:
          require!(
            is_binary(backend[field]) and Path.type(backend[field]) == :absolute and
              File.regular?(backend[field]),
            "explicit backend TLS credential references required"
          )
  end

  defp direct_backend_input(backend) do
    validate_direct_backend!(backend)

    if Map.has_key?(backend, "socket") do
      %{"Socket" => backend["socket"]}
    else
      %{
        "URL" => backend["https"],
        "ServerCert" => File.read!(backend["server_certificate"]),
        "ClientCert" => File.read!(backend["client_certificate"]),
        "ClientKey" => File.read!(backend["client_key"])
      }
    end
  end

  defp safe_proof(result) do
    proof = Map.take(result, @proof_fields)

    proof =
      if result["error"],
        do: Map.put(proof, "error_reference", digest(result["error"])),
        else: proof

    %{"proof" => proof}
  end

  defp private_input(context, input) do
    path =
      Path.join(
        context.runtime,
        "native-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".json"
      )

    File.write!(path, Jason.encode!(input), [:exclusive])
    File.chmod!(path, 0o600)
    path
  end

  defp checked_cli(context, label, args) do
    Acceptance.step(context, label, fn ->
      result = cli(context, args)

      if result.status == 0,
        do: :ok,
        else: {:error, %Opsmaru.Incus.Error{kind: :native_cli_failed}}
    end)
  end

  defp cli(context, args),
    do: command(context.native_cli, args, [{"INCUS_CONF", context.incus_conf}], 180_000)

  @doc false
  def command(executable, args, env, timeout) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        # Input to BEAM only: ordinary native commands receive immediate stdin
        # EOF (snapshot create otherwise waits for YAML on the open pipe).
        :in,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args,
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    try do
      collect(port, "", System.monotonic_time(:millisecond) + timeout)
    after
      if Port.info(port) != nil, do: terminate_owned(port)
    end
  end

  defp collect(port, output, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} ->
        if byte_size(output) + byte_size(data) > 262_144 do
          terminate_owned(port)
          raise "native command output bound exceeded"
        end

        collect(port, output <> data, deadline)

      {^port, {:exit_status, status}} ->
        %{output: output, status: status}
    after
      remaining ->
        terminate_owned(port)
        raise "native command timed out; backend resources retained"
    end
  end

  defp await_json(port, data, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, bytes}} ->
        require!(byte_size(data) + byte_size(bytes) <= 16_384, "accepted identity response bound")

        case String.split(data <> bytes, "\n", parts: 2) do
          [line, _] -> Jason.decode!(line)
          [_] -> await_json(port, data <> bytes, deadline)
        end

      {^port, {:exit_status, _}} ->
        raise "native interruption process ended before acceptance"
    after
      remaining ->
        terminate_owned(port)
        raise "native acceptance identity timeout"
    end
  end

  defp terminate_owned(port) do
    with {:connected, owner} when owner == self() <- Port.info(port, :connected),
         {:os_pid, pid} <- Port.info(port, :os_pid),
         {:connected, ^owner} <- Port.info(port, :connected),
         {:os_pid, ^pid} <- Port.info(port, :os_pid) do
      # Kill only this still-owned native subprocess. SIGKILL bypasses native
      # CLI signal handlers that could otherwise send a remote cancellation.
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      await_owned_exit(port, System.monotonic_time(:millisecond) + 5_000)
    else
      nil -> :ok
      _ -> raise "native command ownership changed"
    end
  end

  defp await_owned_exit(port, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _}} -> await_owned_exit(port, deadline)
    after
      remaining -> raise "owned native command did not terminate"
    end
  end

  defp copy_private(source, destination) do
    File.cp!(source, destination)
    File.chmod!(destination, 0o600)
  end

  defp source_revision do
    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: Path.expand("..", __DIR__))
    String.trim(revision)
  end

  defp escape(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  defp require!(true, _), do: :ok
  defp require!(_, message), do: raise(message)
end
