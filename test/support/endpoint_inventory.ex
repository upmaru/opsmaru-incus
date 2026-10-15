defmodule Opsmaru.TestSupport.EndpointInventory do
  @moduledoc false
  import ExUnit.Assertions

  # Classification and link integrity only: this does not certify behavior.
  def validate!(audit, native) do
    selected = Jason.decode!(File.read!(audit["selected_evidence"]))
    methods = Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
    assert audit["schema"] == 1
    assert audit["reference_revision"] == selected["reference_revision"], "stale reference"
    assert audit["source"] == selected["source"], "stale REST source"
    assert audit["source"] == %{"path" => native["source"], "sha256" => native["sha256"]}
    assert audit["server_sources"] == native["server_sources"], "stale server sources"
    assert audit["classification_complete"] == true
    assert audit["behavior_complete"] == false and audit["complete_port"] == false
    rows = audit["entries"]
    keys = Enum.map(rows, & &1["pair"])
    assert length(keys) == 247 and length(Enum.uniq(keys)) == 247, "duplicate or missing pairs"

    assert Enum.sort(keys) ==
             native["pairs"] |> Enum.map(&normalize/1) |> Enum.uniq() |> Enum.sort()

    views = Enum.flat_map(rows, & &1["documented_views"])

    assert Enum.sort(Enum.map(views, & &1["operation"])) == native["pairs"],
           "missing native views"

    assert Enum.all?(
             views,
             &(&1["query_parameters"] == native["query_parameters"][&1["operation"]])
           ),
           "stale documented query parameters"

    server = Map.new(native["server_routes"], &{normalize(&1["pair"]), &1})
    selected_keys = Enum.map(selected["entries"], &normalize(&1["verb"] <> " " <> &1["path"]))

    assert Enum.frequencies_by(rows, & &1["backlog"]) == %{
             "B01" => 8,
             "B02" => 20,
             "B03" => 4,
             "B04" => 1,
             "B05" => 24,
             "B06" => 2,
             "B07" => 3,
             "B08" => 49,
             "B09" => 53,
             "B10" => 40,
             "B11" => 42,
             "B12" => 1
           },
           "stale backlog partition"

    anchor!(audit["baseline_evidence"])
    for row <- rows, do: row!(row, methods, audit, server, selected_keys)
    extras!(audit, server, keys)
    links!(audit)
    :ok
  end

  defp row!(row, methods, audit, server, selected_keys) do
    key = row["pair"]
    exact = Enum.filter(methods, &(normalize(&1["verb"] <> " " <> &1["path"]) == key))
    custom = Enum.filter(methods, &(custom_pair(&1) == key and &1 not in exact))
    linked = exact ++ custom
    assert row["methods"] == Enum.map(linked, & &1["name"]), "stale method mapping"
    helper_ids = for {id, helper} <- audit["helpers"], helper["pair"] == key, do: id
    assert Enum.sort(row["helpers"]) == Enum.sort(helper_ids), "stale helper mapping"

    expected = classification(key, exact, custom, helper_ids)

    assert row["classification"] == expected, "misleading classification"
    assert row["behavior_complete"] == false, "unsupported completion claim"
    assert audit["backlog"][row["backlog"]]["exit"] not in [nil, ""], "missing backlog"

    expected_server =
      if key == "GET /",
        do: %{"source" => "cmd/incusd/api.go", "symbol" => "restServer", "pair" => "GET /"},
        else: server[key]

    assert row["server"] == expected_server, "stale server mapping"

    if custom != [],
      do: assert(row["restriction"] not in [nil, ""], "missing subtype restriction")

    selected? = key in selected_keys
    assert row["selected_evidence_pair"] == key == selected?

    for view <- row["documented_views"],
        do: view!(view, key, linked, helper_ids, expected, audit["helpers"])

    if mode = row["additional_body_mode"], do: anchor!(mode)
  end

  defp view!(view, key, linked, helper_ids, expected, helpers) do
    assert normalize(view["operation"]) == key, "misplaced native view"

    query =
      view["operation"] |> String.split("?", parts: 2) |> Enum.at(1, "") |> URI.decode_query()

    assert view["selectors"] == Map.delete(query, "public"), "stale query selectors"

    access =
      if Map.has_key?(query, "public"),
        do: "public_documentation_view",
        else: "authenticated_or_default"

    assert view["access"] == access, "misleading public view"

    matching =
      for method <- linked,
          Map.get(method["query"], "recursion", "0") == Map.get(query, "recursion", "0"),
          do: method["name"]

    assert view["methods"] == matching, "stale query mapping"
    parameters!(view, linked, helper_ids, helpers)

    obligation =
      cond do
        access == "public_documentation_view" -> "public_access_evidence_or_scope_decision"
        matching != [] -> "catalogue_selector_evidence"
        helper_ids != [] -> "helper_selector_evidence"
        expected in ["source_discrepancy", "equivalent_route"] -> "source_reconciliation"
        true -> "missing_selector_or_implementation"
      end

    assert view["obligation"] == obligation, "misleading view obligation"
  end

  defp parameters!(view, linked, helper_ids, helpers) do
    bindings =
      Map.new(view["query_parameters"], fn query ->
        kind =
          cond do
            query in ["project", "target"] ->
              "host_routing"

            Map.has_key?(view["selectors"], query) or
                Enum.any?(linked, &Map.has_key?(&1["query"], query)) ->
              "catalogue_contract"

            Enum.any?(helper_ids, &(query in helpers[&1]["supported_queries"])) ->
              "helper_contract"

            true ->
              "unmapped_selector"
          end

        {query, kind}
      end)

    assert view["query_classification"] == bindings, "stale parameter classification"
  end

  defp classification(key, exact, custom, helper_ids) do
    cond do
      key == "GET /1.0/instances/{}/debug/repair" -> "source_discrepancy"
      key == "POST /1.0/storage-pools/{}/volumes" -> "equivalent_route"
      exact != [] -> "catalogue"
      custom != [] -> "catalogue_custom"
      helper_ids != [] -> "helper"
      true -> "missing_typed"
    end
  end

  defp extras!(audit, server, keys) do
    extras = audit["supplemental_server_entries"]

    assert Enum.map(extras, & &1["pair"]) == Enum.sort(Map.keys(server) -- keys),
           "missing server-only pairs"

    for row <- extras do
      assert row["server"] == server[row["pair"]]
      assert row["classification"] == "missing_typed" and row["behavior_complete"] == false
      assert audit["backlog"][row["backlog"]]["exit"] not in [nil, ""]
    end
  end

  defp links!(audit) do
    for helper <- Map.values(audit["helpers"]) do
      [module, function, arity] = helper["client"]
      module = Module.concat([module])
      Code.ensure_loaded!(module)

      assert Enum.any?(module.__info__(:functions), fn {name, count} ->
               Atom.to_string(name) == function and count == arity
             end),
             "missing helper function"

      anchor!(helper["evidence"])
    end

    for contract <- audit["stream_contracts"] do
      assert contract["status"] == "open_contract_certification"
      assert contract["remaining"] not in [nil, ""] and contract["boundary"] not in [nil, ""]
      anchor!(contract["evidence"])
    end

    assert Enum.map(audit["stream_contracts"], & &1["id"]) ==
             Enum.map(1..12, &("S" <> String.pad_leading(to_string(&1), 2, "0")))

    :ok
  end

  defp anchor!([path, anchor]) do
    assert anchor != "" and File.regular?(path) and String.contains?(File.read!(path), anchor),
           "missing source anchor"
  end

  defp normalize(pair),
    do: pair |> String.split("?", parts: 2) |> hd() |> String.replace(~r/\{[^}]+\}/, "{}")

  defp custom_pair(method),
    do:
      normalize(
        method["verb"] <>
          " " <> String.replace(method["path"], "/volumes/custom/", "/volumes/{type}/")
      )
end
