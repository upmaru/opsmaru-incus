defmodule Opsmaru.TestSupport.EndpointInventory do
  @moduledoc false
  import ExUnit.Assertions

  # Required cases per completion-record kind; equality rejects removed or invented cases.
  @record_cases %{
    "native_long_poll" =>
      ~w(running completed failed cancelled etag routing native_403 native_404 response_loss_no_replay deadline cancellation caller_loss preflight redaction),
    "event_stream" =>
      ~w(populated field_presence selectors routing native_400 native_403 native_404 no_retry preflight handlers capacity callback_failure owner_loss caller_loss eof malformed overflow byte_bounds deadline cancellation local_wait send peer_closure),
    "async_mutation" =>
      ~w(request accepted_identity running completed failed cancelled routing binding native_403 native_404 native_409 native_412 malformed_reply response_loss_no_replay local_lifetime),
    "sync_cancellation" =>
      ~w(request routing binding native_403 native_404 malformed_reply authoritative_inspection may_cancel_denied single_delete completion_race lost_reply_identity),
    "conditional_patch" =>
      ~w(request field_presence empty_sync routing native_400 native_403 native_404 native_412 restore_rejection response_loss_no_replay deadline cancellation preflight unconditional_rejection),
    "live_exec" =>
      ~w(collected non_waiting interactive record_output user_group_cwd_size empty_output routing upgrade_targets extension_guards control_frames control_range native_400 native_403 native_404 accepted_identity response_loss_no_replay stream_negotiation invalid_stream_metadata pending_status missing_channels redaction preflight stdin_chunking blocked_stdin deadline cancellation owner_loss sink_limit running_failed close_barrier_abrupt peer_closure)
  }
  @evidence_kinds ~w(named_go_differential raw_query_transport independent_fixture)

  # Classification and link integrity, plus reviewed completion-record consistency.
  # Records name their evidence; the canonical check runs the actual tests.
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

    selected_rows =
      Map.new(selected["entries"], &{normalize(&1["verb"] <> " " <> &1["path"]), &1})

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
    for row <- rows, do: row!(row, methods, audit, server, selected_rows)
    extras!(audit, server, keys)
    links!(audit)
    completion!(audit, selected, Map.new(methods, &{&1["name"], &1}))
    :ok
  end

  defp row!(row, methods, audit, server, selected_rows) do
    key = row["pair"]
    exact = Enum.filter(methods, &(normalize(&1["verb"] <> " " <> &1["path"]) == key))
    custom = Enum.filter(methods, &(custom_pair(&1) == key and &1 not in exact))
    linked = exact ++ custom
    assert row["methods"] == Enum.map(linked, & &1["name"]), "stale method mapping"
    helper_ids = for {id, helper} <- audit["helpers"], helper["pair"] == key, do: id
    assert Enum.sort(row["helpers"]) == Enum.sort(helper_ids), "stale helper mapping"

    expected = classification(key, exact, custom, helper_ids)

    assert row["classification"] == expected, "misleading classification"
    assert is_boolean(row["behavior_complete"]), "unsupported completion claim"
    assert audit["backlog"][row["backlog"]]["exit"] not in [nil, ""], "missing backlog"

    expected_server =
      if key == "GET /",
        do: %{"source" => "cmd/incusd/api.go", "symbol" => "restServer", "pair" => "GET /"},
        else: server[key]

    assert row["server"] == expected_server, "stale server mapping"

    if custom != [],
      do: assert(row["restriction"] not in [nil, ""], "missing subtype restriction")

    selected? = Map.has_key?(selected_rows, key)
    assert row["selected_evidence_pair"] == key == selected?

    assert row["verified_scope"] == get_in(selected_rows, [key, "verified_scope"]),
           "stale fixture scope"

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
    parameters!(view, Enum.filter(linked, &(&1["name"] in matching)), helper_ids, helpers)

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

  defp parameters!(view, matched_methods, helper_ids, helpers) do
    bindings =
      Map.new(view["query_parameters"], fn query ->
        kind =
          cond do
            query in ["project", "target"] ->
              "host_routing"

            Map.has_key?(view["selectors"], query) or
                Enum.any?(matched_methods, &Map.has_key?(&1["query"], query)) ->
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
      assert contract["status"] in ["open_contract_certification", "certified"]
      assert contract["remaining"] not in [nil, ""] and contract["boundary"] not in [nil, ""]
      anchor!(contract["evidence"])
    end

    assert Enum.map(audit["stream_contracts"], & &1["id"]) ==
             Enum.map(1..12, &("S" <> String.pad_leading(to_string(&1), 2, "0")))

    :ok
  end

  defp completion!(audit, selected, catalogue) do
    records = audit["completion_records"]
    assert is_map(records), "missing completion records"
    rows = Map.new(audit["entries"], &{&1["pair"], &1})
    streams = Map.new(audit["stream_contracts"], &{&1["id"], &1})

    selected_rows =
      Map.new(selected["entries"], &{normalize(&1["verb"] <> " " <> &1["path"]), &1})

    for row <- audit["entries"] do
      id = row["completion_record"]
      chosen = selected_rows[row["pair"]]

      if row["behavior_complete"] do
        assert records[id] && row["pair"] in records[id]["rows"], "unsupported completion claim"
        assert row["classification"] != "missing_typed", "unsupported completion claim"

        for stream <- Map.get(row, "stream_contracts", []),
            do: assert(streams[stream]["status"] == "certified", "open linked stream contract")

        assert chosen["status"] == "complete" and chosen["completion_record"] == id,
               "stale selected completion"
      else
        assert is_nil(id), "unsupported completion claim"
        if chosen, do: assert(chosen["status"] != "complete", "stale selected completion")
      end
    end

    for stream <- audit["stream_contracts"] do
      id = stream["completion_record"]

      if stream["status"] == "certified",
        do:
          assert(
            records[id] && stream["id"] in records[id]["stream_contracts"],
            "unsupported certification claim"
          ),
        else: assert(is_nil(id), "unsupported certification claim")
    end

    for {id, record} <- records,
        do: record!(id, record, rows, streams, selected_rows, selected["evidence"], catalogue)
  end

  defp record!(id, record, rows, streams, selected_rows, evidence, catalogue) do
    assert Map.has_key?(@record_cases, record["kind"]), "unknown completion record kind"
    required = required_cases(record, catalogue)
    assert approved?(record), "unapproved completion record"
    anchor!(record["design"])
    assert record["rows"] != [], "empty completion record"
    listed = Enum.map(record["rows"], &rows[&1])

    for row <- listed,
        do:
          assert(
            (row && row["behavior_complete"]) and row["completion_record"] == id,
            "unrelated completion record row"
          )

    for stream <- record["stream_contracts"],
        do: assert(streams[stream]["completion_record"] == id, "unrelated completion stream")

    for {field, key} <- [{"methods", "methods"}, {"helpers", "helpers"}] do
      assert Enum.sort(record[field]) ==
               listed |> Enum.flat_map(& &1[key]) |> Enum.uniq() |> Enum.sort(),
             "stale completion #{field}"
    end

    record_views!(record, Enum.flat_map(listed, & &1["documented_views"]))
    assert record["transports"] == ["unix", "mutual_https"], "missing completion transport"
    record_evidence!(record, required, listed, selected_rows, evidence)

    for field <- ~w(bodies result separate_acceptance),
        do:
          assert(is_binary(record[field]) and record[field] != "", "missing completion #{field}")
  end

  # Every documented view is supported with classified selectors or approved-excluded.
  defp record_views!(record, views) do
    excluded = record["excluded_views"]

    assert Enum.sort(record["supported_views"] ++ Map.keys(excluded)) ==
             Enum.sort(Enum.map(views, & &1["operation"])),
           "unlisted completion view"

    for view <- views do
      if view["operation"] in record["supported_views"] do
        for query <- view["query_parameters"],
            do: assert(described?(record["selectors"][query]), "unclassified completion selector")
      else
        assert approved?(excluded[view["operation"]]), "unapproved exclusion"
      end
    end

    for entry <- record["excluded_scope"] ++ record["approved_differences"],
        do: assert(approved?(entry), "unapproved exclusion")
  end

  # Each required case names anchored evidence of a known kind linked to the selected row.
  defp record_evidence!(record, required, listed, selected_rows, evidence) do
    assert Enum.sort(Map.keys(record["cases"])) == Enum.sort(required),
           "missing completion case"

    assert Enum.all?(Map.values(record["cases"]), &(&1 != [])), "missing completion evidence"

    used =
      Enum.uniq(
        List.flatten(Map.values(record["cases"])) ++
          Enum.map(record["rejected_variants"], & &1["evidence"])
      )

    assert Enum.sort(Map.keys(record["evidence_kinds"])) == Enum.sort(used),
           "stale completion evidence kinds"

    for {key, kind} <- record["evidence_kinds"] do
      assert kind in @evidence_kinds, "unknown completion evidence kind"
      assert Map.has_key?(evidence, key), "missing completion evidence"
      anchor!(evidence[key])

      for row <- listed,
          do:
            assert(key in selected_rows[row["pair"]]["evidence"], "unlinked completion evidence")
    end
  end

  # Kinds name the base cases; the catalogue adds what each listed method declares:
  # a body needs body_fields, guarded fields need extension_guards, and a PUT or
  # conditional method needs its ETag precondition.
  defp required_cases(record, catalogue) do
    methods = Enum.map(record["methods"], &catalogue[&1])

    derived =
      for {case, needed?} <- [
            {"body_fields", &(&1["body"] != nil)},
            {"extension_guards", &Enum.any?(&1["guards"], fn guard -> guard["extension"] end)},
            {"etag", &(&1["verb"] == "PUT" or conditional?(&1))}
          ],
          Enum.any?(methods, needed?),
          do: case

    Enum.uniq(@record_cases[record["kind"]] ++ derived)
  end

  # Mirrors the client: explicit conditional descriptors and empty-sync PATCH require an ETag.
  defp conditional?(method), do: method["conditional"] == true or method["result"] == "empty_sync"

  defp described?(value), do: is_binary(value) and String.trim(value) != ""

  defp approved?(%{"approved" => date}) when is_binary(date),
    do: Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, date)

  defp approved?(_), do: false

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
