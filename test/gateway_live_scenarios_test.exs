Code.require_file("../scripts/gateway-acceptance-host.exs", __DIR__)
Code.require_file("../scripts/gateway_live_scenarios.exs", __DIR__)

defmodule Opsmaru.GatewayLiveScenariosTest do
  use ExUnit.Case, async: false
  alias OpsmaruGatewayLiveScenarios, as: Scenarios

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
