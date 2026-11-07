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
