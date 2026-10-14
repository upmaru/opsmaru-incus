defmodule Opsmaru.TestSupport.EndpointEvidence do
  @moduledoc false
  import ExUnit.Assertions

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
    assert length(manifest["entries"]) == 21
    pairs = Enum.map(manifest["entries"], &pair/1)
    assert length(Enum.uniq(pairs)) == length(pairs), "duplicate endpoint pair"
    native_pairs = MapSet.new(native["pairs"], &normalize/1)

    for row <- manifest["entries"] do
      assert MapSet.member?(native_pairs, pair(row)), "missing native endpoint"
      assert row["status"] in ["partial", "missing"], "unsupported completion claim"
      assert is_binary(row["scope"]) and row["scope"] != ""
      assert is_list(row["gaps"]) and row["gaps"] != [], "missing gaps"

      if row["status"] == "missing" do
        assert row["method"] == nil
        assert row["clients"] == [] and row["evidence"] == [] and row["consumer"] == []
      else
        assert row["clients"] != [] and row["evidence"] != [], "missing client/evidence links"
        clients!(manifest, row)
        evidence!(manifest, row)
        method!(methods, native["pairs"], row)
      end
    end

    wait = Enum.find(manifest["entries"], &String.ends_with?(&1["path"], "/wait"))
    assert wait["status"] == "partial" and wait["method"] == "GetOperationWait"
    :ok
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

  defp evidence!(manifest, row) do
    for key <- row["evidence"] do
      assert Map.has_key?(manifest["evidence"], key), "missing evidence link"
      [path, anchor] = manifest["evidence"][key]
      assert File.regular?(path), "missing evidence file"
      ast = path |> File.read!() |> Code.string_to_quoted!()

      {_, tests} =
        Macro.prewalk(ast, [], fn
          {:test, _, [name | _]} = node, names -> {node, [Macro.to_string(name) | names]}
          node, names -> {node, names}
        end)

      assert anchor != "" and Enum.any?(tests, &String.contains?(&1, anchor)),
             "missing test anchor: #{path} #{anchor}"
    end
  end

  defp method!(methods, native_pairs, row) do
    if row["method"] do
      assert "call" in row["clients"] and "typed" in row["evidence"]

      for name <- [row["method"] | Map.get(row, "variants", [])] do
        assert Map.has_key?(methods, name), "missing catalogue method"
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
