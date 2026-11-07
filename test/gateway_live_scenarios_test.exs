Code.require_file("../scripts/gateway-acceptance-host.exs", __DIR__)
Code.require_file("../scripts/gateway-daemon-probe.exs", __DIR__)
Code.require_file("../scripts/gateway_live_scenarios.exs", __DIR__)

defmodule Opsmaru.GatewayLiveScenariosTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  alias OpsmaruGatewayAcceptance, as: Acceptance
  alias OpsmaruGatewayLiveScenarios, as: Scenarios

  test "successful cleanup leaves the forbidden default profile for native project deletion" do
    root =
      Path.join(
        System.tmp_dir!(),
        "gateway-cleanup-default-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    marker = "cleanup-marker"

    projects = %{
      "source" => "opsmaru-acceptance-gateway-cleanup-source",
      "target" => "opsmaru-acceptance-gateway-cleanup-target"
    }

    state = start_supervised!({Agent, fn -> MapSet.new(Map.values(projects)) end})
    profile = %{"name" => "default", "config" => %{}, "devices" => %{}}

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "backend.sock"),
         handler: fn request ->
           path = URI.parse(request.target).path

           case {request.method, path} do
             {"GET", "/1.0"} ->
               cleanup_sync(%{
                 api_version: "1.0",
                 auth: "trusted",
                 api_extensions: ["projects"],
                 environment: %{}
               })

             {"GET", "/1.0/profiles"} ->
               cleanup_sync([profile])

             {"GET", "/1.0/profiles/default"} ->
               cleanup_sync(profile)

             {"DELETE", "/1.0/profiles/default"} ->
               %{
                 status: 403,
                 body: %{
                   type: "error",
                   error_code: 403,
                   error: "The default profile cannot be deleted"
                 }
               }

             {"GET", "/1.0/projects/" <> name} ->
               if Agent.get(state, &MapSet.member?(&1, name)) do
                 cleanup_sync(%{
                   "name" => name,
                   "description" => "Opsmaru gateway acceptance " <> marker,
                   "config" => %{
                     "features.profiles" => "true",
                     "features.storage.volumes" => "true"
                   }
                 })
               else
                 %{
                   status: 404,
                   body: %{type: "error", error_code: 404, error: "Project not found"}
                 }
               end

             {"DELETE", "/1.0/projects/" <> name} ->
               Agent.update(state, &MapSet.delete(&1, name))
               cleanup_sync(%{})

             {"GET", _} ->
               cleanup_sync([])
           end
         end}
      )

    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :cleanup_fixture)

    {:ok, client} =
      Incus.connect(
        connection,
        Context.new!(owner: :cleanup_fixture, identity: :verified, ready?: fn -> true end)
      )

    journal =
      start_supervised!(
        {Agent,
         fn ->
           %{
             "steps" => [],
             "details" => [],
             "cases" => Map.new(Acceptance.required_cases(), &{&1, "passed"})
           }
         end},
        id: :journal
      )

    config =
      Map.new(projects, fn {side, project} ->
        {side, %{"project" => project, "pool" => "pool"}}
      end)
      |> Map.put("report", Path.join(root, "report.json"))

    context = %{
      config: config,
      marker: marker,
      resource_prefix: "gw-0123456789ab-",
      journal: journal,
      clients: Map.new(projects, fn {side, _} -> {side, client} end),
      sides:
        Map.new(projects, fn {side, project} ->
          {side, %{client: Incus.project(client, project)}}
        end)
    }

    assert :ok = Scenarios.cleanup_owned(context)
    requests = HTTPFixture.requests(fixture)
    refute Enum.any?(requests, &(&1.method == "DELETE" and &1.target =~ "/profiles/"))
    assert Enum.count(requests, &(&1.method == "GET" and &1.target =~ "/profiles/default")) == 2
    assert Enum.count(requests, &(&1.method == "DELETE" and &1.target =~ "/projects/")) == 2
    assert Agent.get(journal, & &1["cleanup"]) == "verified-projects-absent"
    assert Agent.get(state, &MapSet.size/1) == 0
  end

  defp cleanup_sync(metadata),
    do: %{status: 200, body: %{type: "sync", status_code: 200, metadata: metadata}}

  test "migration uses the verified daemon peer for the actual receiving gateway only" do
    peers = %{"source" => true, "target" => false}
    assert Scenarios.migration_peer_available?(peers, "pull", "source", "target")
    refute Scenarios.migration_peer_available?(peers, "push", "source", "target")
    refute Scenarios.migration_peer_available?(peers, "pull", "target", "source")
    assert Scenarios.migration_peer_available?(peers, "push", "target", "source")
    assert Scenarios.migration_peer_available?(%{}, "relay", "source", "target")
    refute Scenarios.migration_peer_available?(%{}, "pull", "source", "target")
    refute Scenarios.migration_peer_available?(%{}, "push", "source", "target")
  end

  test "HTTPS direct comparison uses only the backend TLS identity and rejects mismatches before I/O" do
    root =
      Path.join(
        System.tmp_dir!(),
        "gateway-direct-https-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    server = TLSIdentity.generate(root, "backend-server", "localhost")
    client = TLSIdentity.generate(root, "backend-client", "backend-client")

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: server.certfile,
         keyfile: server.keyfile,
         peer_options: [
           verify: :verify_peer,
           fail_if_no_peer_cert: true,
           cacertfile: client.cafile
         ],
         handler: fn request ->
           if URI.parse(request.target).path == "/1.0" do
             %{
               status: 200,
               body: %{
                 type: "sync",
                 status_code: 200,
                 metadata: %{
                   api_version: "1.0",
                   auth: "trusted",
                   api_extensions: ["instance_nbd"],
                   environment: %{}
                 }
               }
             }
           else
             %{
               status: 400,
               body: %{
                 type: "error",
                 error_code: 400,
                 error: "NBD export of all disks is only supported on virtual machines"
               }
             }
           end
         end}
      )

    backend = %{
      "https" => HTTPFixture.endpoint(fixture).url,
      "server_certificate" => server.certfile,
      "client_certificate" => client.certfile,
      "client_key" => client.keyfile
    }

    context = %{
      config: %{
        "source" => %{
          "project" => "opsmaru-acceptance-gateway-fixture",
          "backend" => backend,
          "gateway" => %{
            "server_certificate" => "/never-read-gateway-cert",
            "client_certificate" => "/never-read-gateway-client",
            "client_key" => "/never-read-gateway-key"
          }
        }
      }
    }

    bad = put_in(context, [:config, "source", "backend", "socket"], "/never-opened-backend.sock")

    assert_raise RuntimeError, "one explicit backend transport required", fn ->
      Scenarios.driver_input(bad, "source", "nbd_instance", %{}, direct: true)
    end

    assert HTTPFixture.requests(fixture) == []

    input =
      Scenarios.driver_input(context, "source", "nbd_instance", %{"Name" => "gw-fixture-name"},
        direct: true
      )

    refute Map.has_key?(input, "Socket")
    assert input["ServerCert"] == File.read!(server.certfile)
    assert input["ClientCert"] == File.read!(client.certfile)
    assert input["ClientKey"] == File.read!(client.keyfile)
    executable = Path.join(root, "native-driver")

    {output, status} =
      System.cmd(
        "mise",
        ["exec", "--", "go", "build", "-mod=readonly", "-o", executable, "./gatewaylive"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    input_path = Path.join(root, "input.json")
    File.write!(input_path, Jason.encode!(input))
    result = Scenarios.command(executable, [input_path], [], 10_000)
    assert result.status == 0
    assert Jason.decode!(result.output)["http_status"] == 400
    assert length(HTTPFixture.requests(fixture)) == 2
  end

  test "expected native denials do not require a success flag and unexpected errors fail" do
    assert Scenarios.expected_driver_result?(%{"http_status" => 403}, expected_status: 403)
    refute Scenarios.expected_driver_result?(%{"http_status" => 500}, expected_status: 403)
    refute Scenarios.expected_driver_result?(%{"error" => "native failure"}, [])
  end

  test "expected verifier errors require the precise kind and a negative error result" do
    known = %{
      "error_kind" => "native_nbd_readonly_unavailable",
      "error" => "strict verifier error"
    }

    opts = [expected_error_kind: "native_nbd_readonly_unavailable"]
    assert Scenarios.expected_driver_result?(known, opts)
    refute Scenarios.expected_driver_result?(known, [])

    refute Scenarios.expected_driver_result?(
             %{known | "error_kind" => "native_verifier_failure"},
             opts
           )

    refute Scenarios.expected_driver_result?(Map.delete(known, "error"), opts)
    refute Scenarios.expected_driver_result?(%{known | "error" => ""}, opts)
    refute Scenarios.expected_driver_result?(%{"error" => "unknown"}, opts)
  end

  test "matching strict NBD unavailability remains unrun and permits subsequent cases" do
    context = nbd_journal()

    known = %{
      "error_kind" => "native_nbd_readonly_unavailable",
      "error" => "strict verifier error"
    }

    assert :ok = Scenarios.record_volume_nbd(context, known, known)
    assert :ok = Acceptance.record_case(context, "denial", "passed")
    assert :ok = Acceptance.record_case(context, "interruption", "passed")
    journal = Agent.get(context.journal, & &1)
    assert journal["cases"]["nbd"] == "unrun"
    assert journal["cases"]["denial"] == "passed"
    assert journal["cases"]["interruption"] == "passed"
    refute Acceptance.evidence_complete?(journal["cases"])
    assert [%{"evidence" => evidence}] = journal["details"]
    assert evidence["outcome"] == "unrun"
    assert evidence["native_error"] == known["error_kind"]
    assert evidence["proof"]["requested_writable"] == false
    assert evidence["proof"]["data_writes"] == 0
    refute File.read!(context.config["report"]) =~ "strict verifier error"
  end

  test "NBD mismatches and unknown failures stop without recording an unavailable case" do
    context = nbd_journal()

    known = %{
      "error_kind" => "native_nbd_readonly_unavailable",
      "error" => "strict verifier error"
    }

    unknown = %{known | "error_kind" => "native_verifier_failure"}

    for {gateway, direct} <- [
          {known, unknown},
          {unknown, known},
          {known, nil},
          {known, %{"passed" => true, "readonly" => true, "read_bytes" => 512}},
          {Map.put(known, "http_status", 500), known},
          {Map.delete(known, "error"), known}
        ] do
      assert_raise RuntimeError, "gateway/direct native read-only NBD failure mismatch", fn ->
        Scenarios.record_volume_nbd(context, gateway, direct)
      end
    end

    assert Agent.get(context.journal, & &1["cases"]["nbd"]) == "pending"
    assert Agent.get(context.journal, & &1["details"]) == []

    assert :ok =
             Scenarios.record_volume_nbd(
               context,
               %{"passed" => true, "readonly" => true, "read_bytes" => 512},
               nil
             )

    assert Agent.get(context.journal, & &1["cases"]["nbd"]) == "passed"
  end

  defp nbd_journal do
    root =
      Path.join(
        System.tmp_dir!(),
        "gateway-nbd-journal-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    journal =
      start_supervised!(
        {Agent,
         fn ->
           %{
             "steps" => [],
             "details" => [],
             "cases" =>
               Map.new(Acceptance.required_cases(), &{&1, "passed"}) |> Map.put("nbd", "pending")
           }
         end},
        id: make_ref()
      )

    %{journal: journal, config: %{"report" => Path.join(root, "report.json")}}
  end

  test "noninteractive command gives a direct child stdin EOF and captures both output streams" do
    child =
      "import os,sys; data=sys.stdin.buffer.read(); print('stdin-eof:'+str(len(data))); print('direct-pid:'+str(os.getpid())); sys.stderr.write('stderr-captured\\n')"

    result = Scenarios.command(System.find_executable("python3"), ["-c", child], [], 1_000)
    assert result.status == 0
    assert result.output =~ "stdin-eof:0"
    assert result.output =~ "direct-pid:"
    assert result.output =~ "stderr-captured"
  end

  test "console progress journals identity before acknowledgement and preserves split/coalesced final JSON" do
    for mode <- [:split, :coalesced] do
      context = console_context(mode)
      result = Scenarios.console_command(context, context.script)
      assert result.status == 0
      assert Jason.decode!(result.output)["received_bytes"] == 87
      [%{"evidence" => evidence}] = Agent.get(context.journal, & &1["details"])

      assert evidence == %{
               "accepted" => true,
               "operation" => "22222222-2222-4222-8222-222222222222",
               "sha256" => String.duplicate("a", 64)
             }

      report = File.read!(context.config["report"])
      refute report =~ "nonce-plaintext"
      refute report =~ "secret="
    end
  end

  test "malformed and oversized console progress never enter the journal" do
    for {mode, message} <- [
          malformed: "native console progress invalid",
          oversized: "native console progress bound exceeded"
        ] do
      context = console_context(mode)

      assert_raise RuntimeError, message, fn ->
        Scenarios.console_command(context, context.script)
      end

      assert Agent.get(context.journal, & &1["details"]) == []
      refute File.exists?(context.config["report"])
    end
  end

  test "console result must retain the accepted writer hash and operation identity" do
    context = console_context(:mismatch)

    assert_raise RuntimeError, "native console writer proof mismatch", fn ->
      Scenarios.console_command(context, context.script)
    end

    assert [%{"evidence" => %{"accepted" => true}}] = Agent.get(context.journal, & &1["details"])
  end

  defp console_context(mode) do
    context = nbd_journal()
    script = Path.join(Path.dirname(context.config["report"]), "console.py")

    progress =
      Jason.encode!(%{
        "accepted" => true,
        "writer_operation" => "22222222-2222-4222-8222-222222222222",
        "nonce_sha256" => String.duplicate("a", 64)
      }) <> "\n"

    final =
      Jason.encode!(%{
        "action" => "console",
        "passed" => true,
        "writer_operation" => "22222222-2222-4222-8222-222222222222",
        "nonce_sha256" => String.duplicate(if(mode == :mismatch, do: "b", else: "a"), 64),
        "received_bytes" => 87
      }) <> "\n"

    body = """
    import json,os,sys,time
    progress=#{inspect(progress)}.encode()
    final=#{inspect(final)}.encode()
    mode=#{inspect(Atom.to_string(mode))}
    if mode=='malformed':
        os.write(1,b'{"accepted":true,"writer_operation":"secret=private","nonce_sha256":"bad"}\\n')
    elif mode=='oversized':
        os.write(1,b'x'*2049)
    elif mode=='coalesced':
        os.write(1,progress+final)
    else:
        os.write(1,progress[:13]); time.sleep(0.01); os.write(1,progress[13:])
    ack=sys.stdin.buffer.readline()
    assert ack==b'console-writer-recorded\\n'
    report=json.load(open(#{inspect(context.config["report"])}))
    assert report['details'][-1]['evidence']['operation']=='22222222-2222-4222-8222-222222222222'
    if mode!='coalesced': os.write(1,final)
    """

    File.write!(script, body)
    Map.merge(context, %{script: script, native_driver: System.find_executable("python3")})
  end

  test "CLI failure diagnostics stay private while the journal records only safe references" do
    context = cli_diagnostic_context()

    output =
      <<255, 0>> <> "\nsecret=native-value\nAuthorization: credential\ntrust_token=private\n"

    assert :ok =
             Scenarios.record_cli_failure(context, "copy/instance/relay/source", %{
               status: 1,
               output: output
             })

    journal = Agent.get(context.journal, & &1)
    assert [%{"evidence" => evidence}] = journal["details"]
    assert Enum.sort(Map.keys(evidence)) == ["exit_status", "proof", "sha256"]
    assert evidence["exit_status"] == 1
    assert evidence["sha256"] == Base.encode16(:crypto.hash(:sha256, output), case: :lower)
    assert %{"artifact" => basename} = evidence["proof"]
    assert Regex.match?(~r/\Acli-failure-[0-9a-f]{64}\.log\z/, basename)
    path = Path.join(context.runtime, basename)
    assert File.read!(path) == output
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(context.runtime).mode, 0o777) == 0o700
    report = File.read!(context.config["report"])
    refute report =~ "native-value"
    refute report =~ "Authorization"
    refute report =~ "trust_token"
    refute report =~ context.runtime

    File.write!(path, "operator-preserved")

    assert_raise File.Error, fn ->
      Scenarios.record_cli_failure(context, "copy/instance/relay/source", %{
        status: 1,
        output: output
      })
    end

    assert File.read!(path) == "operator-preserved"
    assert length(Agent.get(context.journal, & &1["details"])) == 1
  end

  test "CLI diagnostics enforce the output bound before creating an artifact" do
    context = cli_diagnostic_context()
    output = :binary.copy(<<0>>, 262_144)

    assert :ok =
             Scenarios.record_cli_failure(context, "setup-bound", %{status: 2, output: output})

    files = File.ls!(context.runtime)

    assert_raise RuntimeError, "bounded CLI failure result required", fn ->
      Scenarios.record_cli_failure(context, "setup-over-bound", %{
        status: 2,
        output: output <> <<0>>
      })
    end

    assert File.ls!(context.runtime) == files
    assert length(Agent.get(context.journal, & &1["details"])) == 1
  end

  test "CLI failure health projects only local readiness, age, liveness and operation count" do
    context = cli_diagnostic_context()
    owner = self()
    last_poll = System.monotonic_time(:millisecond) - 3_000

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             owner: owner,
             ready: true,
             last_poll: last_poll,
             operations: %{"private-operation-id" => %{secret: "private-operation-secret"}},
             trust: %{"private-caller" => "private-trust-token"}
           }
         end},
        id: :cli_health
      )

    context = Map.put(context, :sides, %{"source" => %{host: %{state: state}}})
    assert :ok = Scenarios.record_cli_failure(context, "health", %{status: 1, output: "failure"})
    [%{"evidence" => evidence}] = Agent.get(context.journal, & &1["details"])
    health = evidence["proof"]["host_health"]
    assert Map.keys(health) |> Enum.sort() == ["source", "target"]
    assert health["target"] == %{"available" => false}

    assert Enum.sort(Map.keys(health["source"])) ==
             ~w(known_operation_count last_poll_age_ms owner_alive ready)

    assert health["source"]["ready"] == true
    assert health["source"]["owner_alive"] == true
    assert health["source"]["known_operation_count"] == 1
    assert health["source"]["last_poll_age_ms"] >= 3_000
    report = File.read!(context.config["report"])
    refute report =~ "private-operation"
    refute report =~ "private-caller"
    refute report =~ "private-trust-token"
  end

  test "unresponsive health Agent cannot delay or replace the CLI failure diagnostic" do
    context = cli_diagnostic_context()
    state = start_supervised!({Agent, fn -> %{} end}, id: :unresponsive_cli_health)
    :ok = :sys.suspend(state)
    context = Map.put(context, :sides, %{"source" => %{host: %{state: state}}})
    started = System.monotonic_time(:millisecond)

    try do
      assert :ok =
               Scenarios.record_cli_failure(context, "unresponsive", %{
                 status: 9,
                 output: "original CLI error"
               })

      assert System.monotonic_time(:millisecond) - started < 1_000
      [%{"evidence" => evidence}] = Agent.get(context.journal, & &1["details"])
      assert evidence["exit_status"] == 9

      assert evidence["proof"]["host_health"] == %{
               "source" => %{"available" => false},
               "target" => %{"available" => false}
             }

      assert File.read!(Path.join(context.runtime, evidence["proof"]["artifact"])) ==
               "original CLI error"
    after
      :sys.resume(state)
    end
  end

  test "CLI diagnostics reject a public or symlink run-state directory" do
    context = cli_diagnostic_context()
    File.chmod!(context.runtime, 0o755)

    assert_raise RuntimeError, "private run-state directory required for CLI diagnostics", fn ->
      Scenarios.record_cli_failure(context, "setup", %{status: 1, output: "failure"})
    end

    File.chmod!(context.runtime, 0o700)
    link = context.runtime <> "-link"
    File.ln_s!(context.runtime, link)
    on_exit(fn -> File.rm!(link) end)

    assert_raise RuntimeError, "private run-state directory required for CLI diagnostics", fn ->
      Scenarios.record_cli_failure(%{context | runtime: link}, "setup", %{
        status: 1,
        output: "failure"
      })
    end

    assert File.ls!(context.runtime) == []
    assert Agent.get(context.journal, & &1["details"]) == []
  end

  defp cli_diagnostic_context do
    context = nbd_journal()
    runtime = Path.dirname(context.config["report"])
    File.chmod!(runtime, 0o700)
    Map.put(context, :runtime, runtime)
  end

  test "bounded command timeout reaps its own noncooperative child" do
    pidfile =
      Path.join(
        System.tmp_dir!(),
        "gateway-owned-child-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    on_exit(fn -> File.rm(pidfile) end)

    child =
      "import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); signal.signal(signal.SIGHUP,signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(2)"

    assert_raise RuntimeError, "native command timed out; backend resources retained", fn ->
      Scenarios.command(System.find_executable("python3"), ["-c", child, pidfile], [], 300)
    end

    pid = pidfile |> File.read!() |> String.to_integer() |> Integer.to_string()
    {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "synchronous native mutations do not poll an empty operation identity" do
    assert Scenarios.operation_path!(%Opsmaru.Incus.Response{type: "sync", operation: ""}) == nil

    assert Scenarios.operation_path!(%Opsmaru.Incus.Response{
             type: "async",
             operation: "/1.0/operations/native-id"
           }) == "/1.0/operations/native-id"

    assert_raise RuntimeError, fn ->
      Scenarios.operation_path!(%Opsmaru.Incus.Response{type: "async", operation: ""})
    end
  end

  test "matrix is exact and invalid run context cannot start a host or backend" do
    matrix = Scenarios.matrix()
    assert length(matrix) == 24
    assert length(Enum.uniq(matrix)) == 24

    assert Enum.count(matrix, fn {action, kind, _, _, _} ->
             action == "move" and kind == "snapshot"
           end) == 6

    listeners = :ranch.info()

    assert_raise RuntimeError, "verified run prefix required", fn ->
      Scenarios.run(%{resource_prefix: "not-an-owned-run"})
    end

    assert :ranch.info() == listeners
  end

  test "strict local configuration rejects duplicate opt-in and oversized input" do
    root =
      Path.join(
        System.tmp_dir!(),
        "gateway-scenario-config-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "config.json")
    File.write!(path, ~s({"allow_namespaced_mutations":false,"allow_namespaced_mutations":true}))

    assert_raise RuntimeError, "duplicate configuration field", fn ->
      Scenarios.load_config!(path)
    end

    File.write!(path, String.duplicate(" ", 65_537))

    assert_raise RuntimeError, "configuration exceeds 64 KiB", fn ->
      Scenarios.load_config!(path)
    end
  end

  test "cleanup rejects foreign resources, changed namespace features and nonempty profiles" do
    marker = "unique"
    prefix = "gw-0123456789ab-"

    project = %{
      "description" => "Opsmaru gateway acceptance " <> marker,
      "config" => %{"features.profiles" => "true", "features.storage.volumes" => "true"}
    }

    instance = %{
      "name" => prefix <> "base",
      "status_code" => 102,
      "config" => %{"user.opsmaru.acceptance.marker" => marker}
    }

    inventory = %{
      project: project,
      instances: [instance],
      volumes: [],
      profiles: [%{"name" => "default", "config" => %{}, "devices" => %{}}],
      snapshots: %{instance["name"] => []}
    }

    assert :ok = Scenarios.validate_owned_inventory!(inventory, prefix, marker)

    for altered <- [
          put_in(inventory, [:project, "config", "features.storage.volumes"], "false"),
          put_in(inventory, [:project, "config", "features.profiles"], "false"),
          %{inventory | instances: [%{instance | "name" => "unowned"}]},
          %{
            inventory
            | instances: [put_in(instance, ["config", "user.opsmaru.acceptance.marker"], "other")]
          },
          %{
            inventory
            | profiles: [
                %{"name" => "default", "config" => %{"user.data" => "preserve"}, "devices" => %{}}
              ]
          }
        ] do
      assert_raise RuntimeError, fn ->
        Scenarios.validate_owned_inventory!(altered, prefix, marker)
      end
    end
  end

  test "native read-only NBD verifier rejects writable export and malformed acknowledgement" do
    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "test", "-timeout", "15s", "./gatewaylive"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
