defmodule Opsmaru.TestSupport.EndpointEvidence do
  @moduledoc false
  import ExUnit.Assertions

  @inspection ~w(GetProjects GetProject GetProfiles GetProfile GetNetworks GetNetwork GetStoragePools GetStoragePool GetStoragePoolVolumes GetStoragePoolVolume)

  @core ~w(GetInstances GetInstance GetInstanceState GetInstanceSnapshots GetInstanceSnapshot GetImages GetImage GetOperations GetOperation)

  @mutation ~w(CreateInstance UpdateInstance UpdateInstanceState DeleteInstance CreateInstanceSnapshot DeleteInstanceSnapshot DeleteImage DeleteOperation)

  # This validates evidence links and provenance, not protocol correctness.
  def validate!(manifest, native) do
    pin = Jason.decode!(File.read!("priv/incus/reference.json"))
    catalogue = Jason.decode!(File.read!(manifest["catalogue"]))
    methods = Map.new(catalogue["methods"], &{&1["name"], &1})
    assert manifest["schema"] == 1
    assert manifest["reference_revision"] == pin["revision"], "stale reference"
    assert catalogue["reference_revision"] == pin["revision"]

    assert manifest["source"] == %{"path" => native["source"], "sha256" => native["sha256"]},
           "stale REST source"

    assert manifest["inventory_complete"] == false
    assert manifest["complete_port"] == false
    assert manifest["catalogue_contracts"] == ~w(query extension guards body model result)
    assert length(manifest["entries"]) == 103
    pairs = Enum.map(manifest["entries"], &pair/1)
    assert length(Enum.uniq(pairs)) == length(pairs), "duplicate endpoint pair"
    native_pairs = MapSet.new(native["pairs"], &normalize/1)

    _cache =
      Enum.reduce(manifest["entries"], %{}, fn row, cache ->
        assert MapSet.member?(native_pairs, pair(row)), "missing native endpoint"
        assert row["status"] in ["partial", "missing", "complete"], "unsupported completion claim"

        # Completion is cross-checked against its reviewed record by EndpointInventory.
        assert is_binary(row["completion_record"]) == (row["status"] == "complete"),
               "unsupported completion claim"

        assert is_binary(row["scope"]) and row["scope"] != ""
        assert is_list(row["gaps"]) and row["gaps"] != [], "missing gaps"

        if row["status"] == "missing" do
          assert row["method"] == nil
          assert row["clients"] == [] and row["evidence"] == [] and row["consumer"] == []
          cache
        else
          assert row["clients"] != [] and row["evidence"] != [], "missing client/evidence links"
          clients!(manifest, row)
          cache = evidence!(manifest, row, cache)
          method!(methods, native["pairs"], row)
          cache
        end
      end)

    inspection!(manifest)
    mutation!(manifest)
    core!(manifest)

    wait = Enum.find(manifest["entries"], &String.ends_with?(&1["path"], "/wait"))
    assert wait["status"] == "complete" and wait["method"] == "GetOperationWait"
    assert wait["variants"] == ["GetOperationWaitSecret"], "missing native secret-wait variant"
    :ok
  end

  defp inspection!(manifest) do
    contract = get_in(manifest, ["fixture_contracts", "initial_inspection_v1"])
    assert is_map(contract), "missing inspection contract"

    assert Enum.sort(Map.keys(manifest["fixture_contracts"])) ==
             ["core_inspection_v1", "initial_inspection_v1", "initial_mutation_lifecycle_v1"],
           "unknown inspection contract"

    assert contract["status"] == "fixture_verified", "invalid inspection contract status"

    assert Enum.sort(contract["methods"] || []) == Enum.sort(@inspection),
           "missing inspection contract methods"

    assert contract["queries"] == "catalogue_only" and contract["volume_types"] == ["custom"],
           "invalid inspection contract scope"

    assert contract["transports"] == ["unix", "mutual_https"],
           "missing inspection contract transport"

    assert contract["cases"] ==
             ~w(populated empty metadata_type_rejection native_403 native_404 response_bound extensions_when_required deadline cancellation),
           "missing inspection contract cases"

    assert contract["evidence"] == ["inspection_contract"], "missing inspection contract evidence"

    for row <- manifest["entries"] do
      expected =
        cond do
          row["method"] in @core or (row["verb"] == "GET" and row["path"] == "/1.0") ->
            "core_inspection_v1"

          row["method"] in @inspection ->
            "initial_inspection_v1"

          row["method"] in @mutation ->
            "initial_mutation_lifecycle_v1"

          true ->
            nil
        end

      assert row["verified_scope"] == expected, "invalid inspection contract attachment"

      if row["method"] in @inspection,
        do:
          assert("inspection_contract" in row["evidence"], "missing inspection contract evidence")
    end
  end

  defp core!(manifest) do
    assert get_in(manifest, ["fixture_contracts", "core_inspection_v1"]) == %{
             "status" => "fixture_verified",
             "methods" => @core,
             "helpers" => ~w(connect),
             "queries" => "catalogue_only",
             "instance_types" => ~w(container),
             "discovery" => "raw_query_transport_and_connect_guards",
             "transports" => ~w(unix mutual_https),
             "cases" =>
               ~w(populated empty metadata_type_rejection native_403 native_404 response_bound readiness deadline cancellation discovery_required_fields discovery_version receive_timeout_classification),
             "evidence" => ~w(core_inspection_contract receive_expiry)
           },
           "invalid core inspection contract"

    for row <- manifest["entries"], row["verified_scope"] == "core_inspection_v1" do
      for key <- ~w(core_inspection_contract receive_expiry),
          do: assert(key in row["evidence"], "missing core inspection contract evidence")
    end
  end

  defp mutation!(manifest) do
    contract = get_in(manifest, ["fixture_contracts", "initial_mutation_lifecycle_v1"])

    assert contract == %{
             "status" => "fixture_verified",
             "methods" => @mutation,
             "transports" => ["unix", "mutual_https"],
             "queries" => "catalogue_only",
             "bodies" => "bounded_fixture_samples_including_restore",
             "cases" =>
               ~w(native_request native_403 native_404 native_409 native_412 response_loss malformed_response no_replay binding),
             "async_cases" =>
               ~w(accepted native_wait_running native_wait_success native_wait_failure etag local_lifetime_after_acceptance),
             "cancel_cases" =>
               ~w(sync_ack may_cancel completion_race native_rejection lost_reply),
             "evidence" => ["mutation_lifecycle", "mutation_cancellation", "native_wait_lifetime"]
           },
           "invalid mutation contract"

    for row <- manifest["entries"], row["method"] in @mutation do
      assert "mutation_lifecycle" in row["evidence"], "missing mutation contract evidence"

      required =
        if row["method"] == "DeleteOperation",
          do: "mutation_cancellation",
          else: "native_wait_lifetime"

      assert required in row["evidence"], "missing mutation contract evidence"
    end
  end

  defp clients!(manifest, row) do
    for key <- row["clients"] do
      assert Map.has_key?(manifest["clients"], key), "missing client link"
      [module, function, arity] = manifest["clients"][key]
      module = Module.concat([module])
      Code.ensure_loaded!(module)

      assert Enum.any?(module.__info__(:functions), fn {name, count} ->
               Atom.to_string(name) == function and count == arity
             end),
             "missing public client function"
    end
  end

  defp evidence!(manifest, row, cache) do
    Enum.reduce(row["evidence"], cache, fn key, cache ->
      assert Map.has_key?(manifest["evidence"], key), "missing evidence link"
      [path, anchor] = manifest["evidence"][key]
      assert File.regular?(path), "missing evidence file"
      tests = Map.get_lazy(cache, path, fn -> test_names!(path) end)

      assert anchor != "" and Enum.any?(tests, &String.contains?(&1, anchor)),
             "missing test anchor: #{path} #{anchor}"

      Map.put(cache, path, tests)
    end)
  end

  # Scoped to one validate! call: every row checks its own anchor, every call rereads source.
  defp test_names!(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_, tests} =
      Macro.prewalk(ast, [], fn
        {:test, _, [name | _]} = node, names -> {node, [Macro.to_string(name) | names]}
        node, names -> {node, names}
      end)

    tests
  end

  defp method!(methods, native_pairs, row) do
    if row["method"] do
      assert "call" in row["clients"]

      for name <- [row["method"] | Map.get(row, "variants", [])] do
        assert Map.has_key?(methods, name), "missing catalogue method"
        # REST-only descriptors (no named Go method) cite their own rest_* typed evidence.
        typed? =
          if methods[name]["reference_kind"] == "rest",
            do: Enum.any?(row["evidence"], &String.starts_with?(&1, "rest_")),
            else: "typed" in row["evidence"]

        assert typed?, "missing typed evidence"
        method = methods[name]
        assert pair(method) == pair(row), "method/endpoint mismatch"
        assert Enum.all?(~w(query extension guards body model result), &Map.has_key?(method, &1))

        if recursion = method["query"]["recursion"] do
          query_pair = pair(row) <> "?recursion=" <> recursion

          assert Enum.any?(native_pairs, &(normalize(&1, false) == query_pair)),
                 "missing native recursion variant"
        end
      end
    else
      refute "call" in row["clients"], "missing catalogue method"
    end
  end

  defp pair(row), do: normalize(row["verb"] <> " " <> row["path"])

  defp normalize(pair, strip_query \\ true) do
    pair = if strip_query, do: hd(String.split(pair, "?", parts: 2)), else: pair
    String.replace(pair, ~r/\{[^}]+\}/, "{}")
  end
end
