defmodule Opsmaru.Incus.EndpointEvidenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.TestSupport.EndpointEvidence
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

  test "21 selected pairs have pinned REST provenance and specific existing evidence", %{
    native: native
  } do
    assert :ok = EndpointEvidence.validate!(@manifest, native)

    assert Enum.sort(Enum.flat_map(@manifest["entries"], &List.wrap(&1["method"]))) ==
             Enum.sort(~w(GetInstances CreateInstance GetInstance UpdateInstance DeleteInstance
               GetInstanceState UpdateInstanceState GetInstanceSnapshots CreateInstanceSnapshot
               GetInstanceSnapshot DeleteInstanceSnapshot GetImages GetImage DeleteImage
               GetOperations GetOperation DeleteOperation GetOperationWait ExecInstance))

    assert Enum.frequencies_by(@manifest["entries"], & &1["status"]) == %{
             "partial" => 21
           }

    coverage = Jason.decode!(File.read!("priv/incus/coverage.json"))
    assert coverage["endpoint_evidence"] == "priv/incus/endpoint-evidence.json"
    assert coverage["complete_port"] == false

    assert Enum.frequencies_by(coverage["entries"], & &1["status"]) == %{
             "partial" => 1239,
             "missing" => 41
           }
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
