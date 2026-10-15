defmodule Opsmaru.Incus.EndpointEvidenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.TestSupport.{EndpointEvidence, EndpointInventory}
  @manifest Jason.decode!(File.read!("priv/incus/endpoint-evidence.json"))

  setup_all do
    reference_dir = Path.expand("reference", __DIR__)
    env = [{"GOTOOLCHAIN", "local"}]

    {out, 0} =
      System.cmd(
        "mise",
        ["exec", "--", "go", "mod", "download", "-json", "github.com/lxc/incus/v7"],
        cd: reference_dir,
        env: env
      )

    module = Jason.decode!(out)
    assert module["Version"] == "v7.0.1"
    driver = Path.expand("../.integration/endpoint-evidence-driver", __DIR__)

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", driver, "./endpoints"],
        cd: reference_dir,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, out
    {out, 0} = System.cmd(driver, [module["Dir"]])
    %{native: Jason.decode!(out)}
  end

  test "full inventory classifies every REST view and reconciles server registrations", %{
    native: native
  } do
    audit = Jason.decode!(File.read!("priv/incus/endpoint-inventory.json"))
    assert :ok = EndpointInventory.validate!(audit, native)

    [first | rest] = audit["entries"]
    [view | other_views] = first["documented_views"]
    views = [%{view | "selectors" => %{"recursion" => "99"}} | other_views]
    wrong_parameters = [%{view | "query_parameters" => ["absent"]} | other_views]

    for changed <- [
          %{audit | "entries" => rest},
          %{audit | "entries" => [%{first | "documented_views" => wrong_parameters} | rest]},
          %{audit | "entries" => [%{first | "documented_views" => views} | rest]},
          put_in(audit, ["helpers", "connect", "client"], ["Opsmaru.Incus", "absent", 2]),
          put_in(audit, ["baseline_evidence"], ["test/resource_slice_test.exs", "absent anchor"]),
          %{audit | "entries" => [first, first | rest]},
          put_in(audit, ["entries"], [Map.put(first, "methods", ["AbsentMethod"]) | rest]),
          put_in(audit, ["entries"], [Map.put(first, "backlog", "absent") | rest]),
          put_in(audit, ["entries"], [Map.put(first, "behavior_complete", true) | rest]),
          put_in(audit, ["entries"], [Map.put(first, "documented_views", []) | rest]),
          %{audit | "server_sources" => %{}},
          %{audit | "supplemental_server_entries" => []},
          %{audit | "behavior_complete" => true},
          %{audit | "stream_contracts" => []}
        ] do
      assert_raise ExUnit.AssertionError, fn ->
        EndpointInventory.validate!(changed, native)
      end
    end
  end

  test "query parameters cannot borrow support from another recursion view", %{native: native} do
    audit = Jason.decode!(File.read!("priv/incus/endpoint-inventory.json"))

    gaps =
      for row <- audit["entries"],
          not String.starts_with?(row["pair"], "HEAD "),
          view <- row["documented_views"],
          {query, "unmapped_selector"} <- view["query_classification"],
          do: {row["pair"], query}

    assert gaps |> Enum.uniq() |> length() == 28
    assert length(gaps) == 38
    row = Enum.find(audit["entries"], &(&1["pair"] == "GET /1.0/instances"))
    names = Enum.find(row["documented_views"], &(&1["operation"] == "GET /1.0/instances"))
    assert names["methods"] == ["GetInstanceNames"]
    assert names["query_classification"]["filter"] == "unmapped_selector"
    assert names["query_classification"]["all-projects"] == "unmapped_selector"

    full = Enum.find(row["documented_views"], &String.ends_with?(&1["operation"], "?recursion=1"))
    assert full["query_classification"]["filter"] == "catalogue_contract"
    assert full["query_classification"]["all-projects"] == "catalogue_contract"

    views =
      Enum.map(row["documented_views"], fn view ->
        if view == names,
          do: put_in(view, ["query_classification", "filter"], "catalogue_contract"),
          else: view
      end)

    entries =
      Enum.map(
        audit["entries"],
        &if(&1 == row, do: %{row | "documented_views" => views}, else: &1)
      )

    assert_raise ExUnit.AssertionError, ~r/stale parameter classification/, fn ->
      EndpointInventory.validate!(%{audit | "entries" => entries}, native)
    end
  end

  test "full inventory fixture claims must match the selected evidence scope", %{native: native} do
    audit = Jason.decode!(File.read!("priv/incus/endpoint-inventory.json"))
    verified = Enum.find(audit["entries"], &(&1["pair"] == "GET /1.0/projects"))
    unrelated = Enum.find(audit["entries"], &(&1["pair"] == "GET /1.0/certificates"))

    for {row, replacement} <- [
          {verified, Map.delete(verified, "verified_scope")},
          {verified, Map.put(verified, "verified_scope", "invented_scope")},
          {unrelated, Map.put(unrelated, "verified_scope", "initial_inspection_v1")}
        ] do
      entries = Enum.map(audit["entries"], &if(&1 == row, do: replacement, else: &1))

      assert_raise ExUnit.AssertionError, ~r/fixture scope/, fn ->
        EndpointInventory.validate!(%{audit | "entries" => entries}, native)
      end
    end
  end

  test "32 selected pairs have pinned REST provenance and specific existing evidence", %{
    native: native
  } do
    assert :ok = EndpointEvidence.validate!(@manifest, native)

    assert Enum.sort(Enum.flat_map(@manifest["entries"], &List.wrap(&1["method"]))) ==
             Enum.sort(
               ~w(GetInstances CreateInstance GetInstance UpdateInstance PatchInstance DeleteInstance
               GetInstanceState UpdateInstanceState GetInstanceSnapshots CreateInstanceSnapshot
               GetInstanceSnapshot DeleteInstanceSnapshot GetImages GetImage DeleteImage
               GetOperations GetOperation DeleteOperation GetOperationWait ExecInstance
               GetProjects GetProject GetProfiles GetProfile GetNetworks GetNetwork
               GetStoragePools GetStoragePool GetStoragePoolVolumes GetStoragePoolVolume)
             )

    assert Enum.frequencies_by(@manifest["entries"], & &1["status"]) == %{
             "partial" => 32
           }

    coverage = Jason.decode!(File.read!("priv/incus/coverage.json"))
    assert coverage["endpoint_evidence"] == "priv/incus/endpoint-evidence.json"
    assert coverage["complete_port"] == false

    assert Enum.frequencies_by(coverage["entries"], & &1["status"]) == %{
             "partial" => 1239,
             "missing" => 41
           }
  end

  test "rejects incomplete or overclaimed inspection contracts", %{native: native} do
    path = ["fixture_contracts", "initial_inspection_v1"]

    for {field, value} <- [
          {"methods", ["GetProject"]},
          {"cases", ["populated"]},
          {"transports", ["unix"]},
          {"evidence", []},
          {"status", "complete"},
          {"queries", "all"},
          {"volume_types", ["all"]}
        ] do
      changed = put_in(@manifest, path ++ [field], value)

      assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
        EndpointEvidence.validate!(changed, native)
      end
    end

    [first | rest] = @manifest["entries"]

    for changed <- [
          put_in(@manifest, ["fixture_contracts", "unsupported"], %{"status" => "complete"}),
          %{
            @manifest
            | "entries" => [Map.put(first, "verified_scope", "initial_inspection_v1") | rest]
          }
        ] do
      assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
        EndpointEvidence.validate!(changed, native)
      end
    end

    entries = Enum.map(@manifest["entries"], &Map.delete(&1, "verified_scope"))

    assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
      EndpointEvidence.validate!(%{@manifest | "entries" => entries}, native)
    end

    assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
      EndpointEvidence.validate!(Map.delete(@manifest, "fixture_contracts"), native)
    end
  end

  test "rejects removed native secret-wait variants", %{native: native} do
    wait = Enum.find(@manifest["entries"], &(&1["method"] == "GetOperationWait"))

    for removed <- [Map.delete(wait, "variants"), %{wait | "variants" => []}] do
      entries = Enum.map(@manifest["entries"], &if(&1 == wait, do: removed, else: &1))

      assert_raise ExUnit.AssertionError, ~r/missing native secret-wait variant/, fn ->
        EndpointEvidence.validate!(%{@manifest | "entries" => entries}, native)
      end
    end
  end

  for {field, value, message} <- [
        {"reference_revision", "stale", "stale reference"},
        {"source", %{}, "stale REST source"},
        {"inventory_complete", true, "false"},
        {"complete_port", true, "false"}
      ] do
    test "rejects misleading or stale #{field}", %{native: native} do
      assert_raise ExUnit.AssertionError, ~r/#{unquote(message)}/, fn ->
        EndpointEvidence.validate!(
          Map.put(@manifest, unquote(field), unquote(Macro.escape(value))),
          native
        )
      end
    end
  end

  test "rejects duplicate pairs, missing links, misplaced methods and unsupported completion", %{
    native: native
  } do
    [first, second | rest] = @manifest["entries"]

    for {row, message} <- [
          {first, "duplicate endpoint pair"},
          {%{second | "method" => "AbsentMethod"}, "missing catalogue method"},
          {%{second | "method" => "GetImage"}, "method/endpoint mismatch"},
          {Map.put(second, "variants", ["GetImage"]), "method/endpoint mismatch"},
          {%{second | "clients" => ["absent"]}, "missing client link"},
          {%{second | "evidence" => ["absent"]}, "missing evidence link"},
          {%{second | "status" => "complete"}, "unsupported completion claim"},
          {%{second | "gaps" => []}, "missing gaps"},
          {%{second | "path" => "/1.0/not-a-route"}, "missing native endpoint"}
        ] do
      assert_raise ExUnit.AssertionError, ~r/#{message}/, fn ->
        EndpointEvidence.validate!(%{@manifest | "entries" => [first, row | rest]}, native)
      end
    end

    evidence =
      Map.put(@manifest["evidence"], "typed", ["test/resource_slice_test.exs", "absent test"])

    assert_raise ExUnit.AssertionError, ~r/missing test anchor/, fn ->
      EndpointEvidence.validate!(%{@manifest | "evidence" => evidence}, native)
    end
  end
end
