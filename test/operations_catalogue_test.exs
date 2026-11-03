defmodule Opsmaru.Incus.OperationsCatalogueTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Operations
  alias Opsmaru.Incus.Operations.{Descriptor, Evidence, Schema}

  # Public contract: names, schemas, scopes, confirmation rules and bounds.
  # Regenerate deliberately with UPDATE_OPERATIONS_CATALOGUE=1 and review the diff.
  @snapshot Path.expand("fixtures/incus/operations-catalogue.json", __DIR__)

  # Modules that make up the operations layer; calls between them are internal.
  @layer [
    Operations,
    Operations.Exec,
    Operations.Inspection,
    Operations.Instances,
    Operations.Mutation,
    Operations.OperationTools,
    Operations.Result
  ]

  test "canonical names follow incus_<resource>_<verb> and are unique" do
    names = Enum.map(Operations.all(), & &1.name)
    assert names == Enum.sort(Enum.uniq(names))
    assert length(names) == 32

    for name <- names do
      assert name =~ ~r/\Aincus_[a-z0-9]+(_[a-z0-9]+)+\z/ and byte_size(name) <= 64, name
    end

    verbs =
      names |> Enum.map(&(&1 |> String.split("_") |> List.last())) |> Enum.uniq() |> Enum.sort()

    assert verbs == ~w(cancel create delete exec get list restore update wait)
  end

  test "the catalogue matches its reviewed snapshot" do
    catalogue = %{
      "operations" => Enum.map(Operations.all(), &Operations.describe/1),
      "unavailable" => Operations.unavailable()
    }

    if System.get_env("UPDATE_OPERATIONS_CATALOGUE") == "1",
      do: File.write!(@snapshot, Jason.encode!(catalogue, pretty: true) <> "\n")

    assert Jason.decode!(File.read!(@snapshot)) == Jason.decode!(Jason.encode!(catalogue))
  end

  test "schemas use only validated keywords and reject unknown input" do
    for descriptor <- Operations.all() do
      for schema <- [descriptor.input_schema, Operations.output_schema(descriptor)] do
        assert unsupported(schema) == [], descriptor.name
      end

      assert descriptor.input_schema["type"] == "object"
      assert descriptor.input_schema["additionalProperties"] == false

      assert {:error, "/socket", "is not allowed"} =
               descriptor.input_schema
               |> Map.delete("required")
               |> Schema.validate(%{"socket" => "/var/lib/incus/unix.socket"})

      assert :ok =
               Schema.validate(Operations.output_schema(descriptor), %{
                 "error" => %{"kind" => "k", "message" => "m"}
               })
    end
  end

  test "scopes, destructive flags and confirmation rules are consistent" do
    for descriptor <- Operations.all() do
      assert descriptor.scope in Operations.scopes()
      assert descriptor.destructive == (descriptor.scope == "incus.delete"), descriptor.name
      assert descriptor.destructive == not is_nil(descriptor.confirm), descriptor.name
      if descriptor.destructive, do: assert("confirm" in descriptor.input_schema["required"])
    end

    by_scope = Enum.group_by(Operations.all(), & &1.scope, & &1.name)
    assert by_scope["incus.exec"] == ["incus_instance_exec"]

    assert Enum.sort(by_scope["incus.delete"]) ==
             ~w(incus_image_delete incus_instance_delete incus_instance_snapshot_delete incus_instance_snapshot_restore)

    assert Enum.all?(by_scope["incus.read"], &(&1 =~ ~r/_(get|list|wait)\z/))
  end

  test "no input field can select a socket, URL, credential, owner or host path" do
    forbidden =
      ~w(socket url server certificate secret password key token owner connection host path tls)

    for descriptor <- Operations.all(), field <- fields(descriptor.input_schema) do
      refute field in forbidden, "#{descriptor.name} accepts #{field}"
    end
  end

  test "every exported operation has evidence for each client method it uses" do
    for descriptor <- Operations.all() do
      assert descriptor.requires != []

      for requirement <- descriptor.requires,
          do:
            assert({:ok, _} = Evidence.lookup(requirement), "#{descriptor.name}: #{requirement}")
    end
  end

  test "an operation that depends on unevidenced client methods is not exported" do
    pending = %Descriptor{
      name: "incus_instance_copy",
      title: "Copy",
      description: "Not evidenced here.",
      scope: "incus.write",
      input_schema: %{"type" => "object"},
      output_schema: %{"type" => "object"},
      requires: ["CopyInstanceWithoutEvidence"],
      run: fn _, _, _ -> raise "never runs" end
    }

    assert Evidence.missing(pending.requires) == ["CopyInstanceWithoutEvidence"]
    assert Operations.exported([pending | Operations.candidates()]) == Operations.all()
    assert {:error, :no_method_evidence} = Evidence.lookup("CopyInstanceWithoutEvidence")
    assert {:error, :stream_not_certified} = Evidence.lookup("stream:S99")
    assert {:error, :no_helper_evidence} = Evidence.lookup("helper:missing")

    assert {:error, %{"kind" => "unknown_operation"}} =
             Operations.run("incus_instance_copy", %{}, host: nil, scopes: Operations.scopes())

    assert Enum.map(Operations.unavailable(), & &1["name"]) ==
             ~w(incus_instance_copy incus_instance_move incus_instance_rename)

    assert Enum.all?(Operations.unavailable(), &(&1["reason"] =~ "deferred by scope"))
  end

  test "operations call only public client functions" do
    calls =
      for module <- @layer,
          {target, function, arity} <- remote_calls(module),
          String.starts_with?(Atom.to_string(target), "Elixir.Opsmaru.Incus"),
          target not in @layer and
            not String.starts_with?(Atom.to_string(target), "Elixir.Opsmaru.Incus.Operations."),
          uniq: true,
          do: {target, function, arity}

    assert {Opsmaru.Incus, :call, 3} in calls and {Opsmaru.Incus.Session, :exec, 3} in calls

    for {module, function, arity} <- calls do
      assert {:docs_v1, _, _, _, moduledoc, _, docs} = Code.fetch_docs(module)
      refute moduledoc == :hidden, "#{inspect(module)} is internal"

      doc =
        Enum.find_value(docs, fn
          {{:function, ^function, defined}, _, _, doc, meta} ->
            if arity in (defined - Map.get(meta, :defaults, 0))..defined//1, do: doc

          _ ->
            nil
        end)

      assert doc != nil and doc != :hidden,
             "#{inspect(module)}.#{function}/#{arity} is not public"
    end
  end

  test "the documented catalogue table matches the descriptors" do
    doc = File.read!(Path.expand("../docs/incus-operations.md", __DIR__))
    [_, table] = String.split(doc, "<!-- operations-catalogue:start -->")
    [table, _] = String.split(table, "<!-- operations-catalogue:end -->")

    rows =
      for descriptor <- Operations.all() do
        confirm = if descriptor.confirmation, do: descriptor.confirmation["value"], else: "—"
        requires = Enum.map_join(descriptor.requires, ", ", &"`#{&1}`")
        "| `#{descriptor.name}` | `#{descriptor.scope}` | #{confirm} | #{requires} |"
      end

    assert table |> String.split("\n", trim: true) |> Enum.drop(2) == rows
  end

  test "the library defines operations without starting anything" do
    assert Application.spec(:opsmaru_incus, :mod) in [nil, []]
    assert Operations.all() == Operations.all()
  end

  defp unsupported(schema) when is_map(schema) do
    keys = for {key, _} <- schema, key not in Schema.keywords(), do: key

    nested =
      Enum.flat_map(schema, fn
        {"properties", props} ->
          Enum.flat_map(Map.values(props), &unsupported/1)

        {"oneOf", list} ->
          Enum.flat_map(list, &unsupported/1)

        {key, value} when key in ["items", "additionalProperties", "propertyNames"] ->
          unsupported(value)

        _ ->
          []
      end)

    keys ++ nested
  end

  defp unsupported(_), do: []

  defp fields(schema) when is_map(schema) do
    props = Map.get(schema, "properties", %{})
    Map.keys(props) ++ Enum.flat_map(Map.values(props), &fields/1)
  end

  defp fields(_), do: []

  defp remote_calls(module) do
    {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(:code.which(module), [:abstract_code])

    forms |> collect() |> Enum.uniq()
  end

  defp collect({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args} = _node),
    do: [{m, f, length(args)} | collect(args)]

  defp collect({:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}),
    do: [{m, f, a}]

  defp collect(node) when is_tuple(node), do: node |> Tuple.to_list() |> collect()
  defp collect(list) when is_list(list), do: Enum.flat_map(list, &collect/1)
  defp collect(_), do: []
end
