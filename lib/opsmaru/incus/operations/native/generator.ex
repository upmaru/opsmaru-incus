defmodule Opsmaru.Incus.Operations.Native.Generator do
  @moduledoc false
  # Builds the native operations document from the verified method registry.
  #
  # `methods.json` decides which operations exist and `models.json` their
  # schemas. The reviewed policy excludes methods, removes body fields and
  # overrides scopes, destructive flags and confirmation targets. The upstream
  # `rest-api.yaml` contributes summaries and descriptions only, joined by verb
  # and normalized path; it never adds an operation or a schema.
  #
  # `build/1` is a pure function of its inputs, so tests run it on fixtures.
  # `mix opsmaru.incus.native` runs it on `priv/incus` and writes
  # `native-operations.json`; `Opsmaru.Incus.Operations.Native` reads that file
  # at compile time.
  alias Opsmaru.Incus.Operations.{Evidence, Fragments}

  @source "opsmaru_incus_native"
  @ref "#/components/schemas/"
  @interactive_bodies ~w(InstanceExecPost InstanceConsolePost)
  @scopes ~w(incus.native.read incus.native.write incus.native.delete incus.native.admin)
  @integers ~w(int int8 int16 int32 int64)
  @unsigned ~w(uint uint8 uint16 uint32 uint64)
  @reserved ~w(project etag body confirm)
  @no_control "^[^\\x00-\\x1f\\x7f]+$"

  @rules %{
    interactive: "interactive_channel",
    binary: "binary_transfer",
    remote: "remote_backend_or_credential",
    evidence: "no_evidence"
  }

  def scopes, do: @scopes

  @doc "Operation ID of a native method: `incus_native_` plus its snake-case name."
  def operation_id(method) do
    snake =
      ~r/([A-Z])([A-Z]+)s(?=[A-Z]|$)/
      |> Regex.replace(method, fn _, first, rest -> first <> String.downcase(rest) <> "s" end)
      |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.downcase()

    "incus_native_" <> snake
  end

  @doc """
  Read the generator inputs from a `priv/incus` directory. The upstream YAML is
  parsed only after its SHA-256 matches the one recorded in the policy.
  """
  def load(directory) do
    read = fn name -> directory |> Path.join(name) |> File.read!() |> Jason.decode!() end
    policy = read.("native-policy.json")
    methods = read.("methods.json")
    yaml = File.read!(Path.join(directory, get_in(policy, ["upstream", "file"]) || ""))
    digest = Base.encode16(:crypto.hash(:sha256, yaml), case: :lower)

    cond do
      digest != get_in(policy, ["upstream", "sha256"]) ->
        {:error, ["rest-api.yaml SHA-256 #{digest} differs from the recorded one"]}

      methods["reference_revision"] != get_in(policy, ["upstream", "revision"]) ->
        {:error, ["rest-api.yaml revision differs from the methods.json reference revision"]}

      true ->
        [upstream] =
          :yamerl_constr.string(yaml, [:str_node_as_binary, {:map_node_format, :map}])

        {:ok,
         %{
           methods: methods["methods"],
           models: read.("models.json")["models"],
           policy: policy,
           upstream: upstream,
           revision: methods["reference_revision"],
           evidence: &match?({:ok, _}, Evidence.lookup(&1))
         }}
    end
  end

  @doc "The generated file's bytes: sorted keys, two-space indentation, final newline."
  def encode(generated),
    do: (generated |> ordered() |> Jason.encode!(pretty: true)) <> "\n"

  defp ordered(%{} = map),
    do:
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
      |> Jason.OrderedObject.new()

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  @doc """
  Build `%{"schema" => 1, "document" => ..., "unavailable" => [...]}` or
  `{:error, reasons}`. The document has no `info.version`; the native module
  adds the package version.
  """
  def build(%{methods: methods, models: models, policy: policy} = inputs) do
    upstream = Map.get(inputs, :upstream, %{})
    evidence = Map.get(inputs, :evidence, fn _ -> true end)

    case policy_errors(policy, methods, models) do
      [] ->
        context = %{
          models: models,
          definitions: Map.get(upstream, "definitions") || %{},
          text: upstream_index(upstream),
          denied: denied(policy),
          overrides: Map.new(policy["overrides"], &{&1["method"], &1})
        }

        classified = Enum.map(methods, &{&1, classify(&1, policy, evidence)})
        generate(classified, context, policy, inputs)

      errors ->
        {:error, errors}
    end
  catch
    {:generator, reason} -> {:error, [reason]}
  end

  defp generate(classified, context, policy, inputs) do
    exported = for {method, :exported} <- classified, do: operation(method, context)

    unavailable =
      for {method, {rule, reason}} <- classified do
        %{
          "name" => operation_id(method["name"]),
          "method" => method["name"],
          "rule" => @rules[rule],
          "reason" => reason
        }
      end

    components = components(exported, context)

    errors =
      override_errors(policy, classified) ++
        accounting_errors(classified, exported, unavailable) ++
        Enum.flat_map(exported, &operation_errors/1) ++ duplicate_errors(exported)

    if errors == [] do
      {:ok,
       %{
         "schema" => 1,
         "document" => document(exported, components, inputs),
         "unavailable" => Enum.sort_by(unavailable, & &1["name"])
       }}
    else
      {:error, errors}
    end
  end

  defp document(exported, components, inputs) do
    %{
      "openapi" => "3.1.1",
      "jsonSchemaDialect" => "https://spec.openapis.org/oas/3.1/dialect/base",
      "info" => %{"title" => "opsmaru_incus native operations"},
      "x-tama-profile" => "tama-operations/1",
      "x-tama-source" => @source,
      "x-opsmaru-reference-revision" => Map.get(inputs, :revision),
      "paths" => Map.new(exported, &{"/operations/" <> &1["operationId"], %{"post" => &1}}),
      "components" => %{"schemas" => components}
    }
  end

  # Policy

  defp policy_errors(policy, methods, models) do
    exclusions = Map.get(policy, "exclusions") || %{}
    binary = Map.get(exclusions, "binary_transfer") || []
    remote = Map.get(exclusions, "remote_backend_or_credential") || []
    overrides = Map.get(policy, "overrides") || []
    denylist = Map.get(policy, "body_field_denylist") || []

    List.flatten([
      if(policy["schema"] == 1, do: [], else: ["policy schema must be 1"]),
      for(
        key <- ~w(exclusions overrides body_field_denylist),
        not Map.has_key?(policy, key),
        do: "policy has no #{key}"
      ),
      for(
        entry <- binary ++ remote ++ overrides ++ denylist,
        not reason?(entry),
        do: "policy entry #{inspect(entry["method"] || entry["model"])} has no reason"
      ),
      name_errors(Enum.map(binary ++ remote, & &1["method"]), overrides, methods),
      Enum.flat_map(overrides, &override_shape/1),
      Enum.flat_map(denylist, &denylist_shape(&1, models))
    ])
  end

  # Every named method exists, and none is excluded or overridden twice.
  defp name_errors(excluded, overrides, methods) do
    names = MapSet.new(methods, & &1["name"])
    overridden = Enum.map(overrides, & &1["method"])

    for(
      name <- excluded ++ overridden,
      not MapSet.member?(names, name),
      do: "policy names unknown method #{inspect(name)}"
    ) ++
      for(name <- Enum.uniq(excluded -- Enum.uniq(excluded)), do: "policy excludes #{name} twice") ++
      for name <- Enum.uniq(overridden -- Enum.uniq(overridden)),
          do: "policy overrides #{name} twice"
  end

  defp reason?(%{"reason" => reason}), do: is_binary(reason) and String.trim(reason) != ""
  defp reason?(_), do: false

  defp override_shape(%{"method" => method} = override) do
    List.flatten([
      if(Map.keys(override) -- ~w(method reason scope destructive confirm) == [],
        do: [],
        else: "override for #{method} has unknown keys"
      ),
      if(map_size(Map.drop(override, ~w(method reason))) > 0,
        do: [],
        else: "override for #{method} changes nothing"
      ),
      if(Map.get(override, "scope", hd(@scopes)) in @scopes,
        do: [],
        else: "override for #{method} names an unknown scope"
      ),
      if(is_boolean(Map.get(override, "destructive", true)),
        do: [],
        else: "override for #{method} has a non-boolean destructive flag"
      ),
      case Map.get(override, "confirm") do
        nil -> []
        %{"param" => param} = confirm when is_binary(param) and map_size(confirm) == 1 -> []
        %{"value" => value} = confirm when is_binary(value) and map_size(confirm) == 1 -> []
        _ -> "override for #{method} has an invalid confirm target"
      end
    ])
  end

  defp override_shape(_), do: ["an override names no method"]

  defp denylist_shape(%{"model" => model, "fields" => [_ | _] = fields}, models) do
    case models[model] do
      %{"kind" => "struct", "fields" => declared} ->
        known = Enum.map(declared, & &1["name"])

        for field <- fields,
            field not in known,
            do: "denylist names unknown field #{model}.#{field}"

      _ ->
        ["denylist names unknown model #{inspect(model)}"]
    end
  end

  defp denylist_shape(entry, _), do: ["denylist entry #{inspect(entry["model"])} lists no fields"]

  defp denied(policy) do
    Map.new(policy["body_field_denylist"], &{&1["model"], MapSet.new(&1["fields"])})
  end

  # Exclusion rules, in order.
  defp classify(method, policy, evidence) do
    name = method["name"]
    listed = fn key -> Enum.find(policy["exclusions"][key] || [], &(&1["method"] == name)) end

    cond do
      method["body"] in @interactive_bodies ->
        {:interactive,
         "interactive channel: the operation opens websockets; use the composite incus_instance_exec to run commands"}

      entry = listed.("binary_transfer") ->
        {:binary, entry["reason"]}

      entry = listed.("remote_backend_or_credential") ->
        {:remote, entry["reason"]}

      not evidence.(name) ->
        {:evidence, "missing client evidence"}

      true ->
        :exported
    end
  end

  defp override_errors(policy, classified) do
    excluded = for {method, {_, _}} <- classified, into: MapSet.new(), do: method["name"]

    for %{"method" => name} <- policy["overrides"],
        MapSet.member?(excluded, name),
        do: "policy overrides excluded method #{name}"
  end

  # Every method is either exported or listed as unavailable, never both.
  defp accounting_errors(classified, exported, unavailable) do
    all = Enum.map(classified, fn {method, _} -> method["name"] end)
    out = Enum.map(exported, & &1["x-opsmaru-native"]["method"])
    listed = Enum.map(unavailable, & &1["method"])

    for(name <- all -- (out ++ listed), do: "#{name} is neither exported nor unavailable") ++
      for(name <- out, name in listed, do: "#{name} is both exported and unavailable") ++
      for name <- all -- Enum.uniq(all), do: "method #{name} is registered twice"
  end

  defp duplicate_errors(exported) do
    ids = Enum.map(exported, & &1["operationId"])
    for id <- Enum.uniq(ids -- Enum.uniq(ids)), do: "duplicate operation ID #{id}"
  end

  defp operation_errors(operation) do
    id = operation["operationId"]

    List.flatten([
      if(id =~ ~r/\A[a-z][a-z0-9_]{0,127}\z/, do: [], else: "invalid operation ID #{id}"),
      if(String.length(operation["summary"]) in 1..120, do: [], else: "#{id}: summary length"),
      if(String.length(operation["description"]) in 1..4096,
        do: [],
        else: "#{id}: description length"
      )
    ])
  end

  # Operations

  defp operation(method, context) do
    override = Map.get(context.overrides, method["name"], %{})
    destructive = Map.get(override, "destructive", method["verb"] in ["DELETE", "PUT"])

    if Map.has_key?(override, "confirm") and not destructive,
      do: throw({:generator, "#{method["name"]}: confirm override on a non-destructive method"})

    confirm = if destructive, do: confirm_target(method, override)
    text = upstream_text(method, context.text)
    etag = etag(method)

    native =
      %{
        "method" => method["name"],
        "verb" => method["verb"],
        "path" => method["path"],
        "result" => method["result"],
        "params" => method["params"],
        "etag" => etag
      }
      |> put_if("confirm", confirm)

    %{
      "operationId" => operation_id(method["name"]),
      "summary" => text["summary"] || "#{method["verb"]} #{method["path"]}",
      "description" => description(method, text["description"], etag),
      "tags" => ["native", tag(method["path"])],
      "x-tama-scopes" => [Map.get(override, "scope", scope(method))],
      "x-tama-destructive" => destructive,
      "x-tama-bounds" => %{"max_input_bytes" => 65_536, "max_output_bytes" => 262_144},
      "x-opsmaru-requires" => [method["name"]],
      "x-opsmaru-native" => native,
      "requestBody" => %{"required" => true, "content" => json(input(method, confirm, etag))},
      "responses" => %{
        "200" => %{"description" => "Native result", "content" => json(output(method))},
        "default" => %{"description" => "Error", "content" => json(ref("Error"))}
      }
    }
    |> put_if("x-tama-confirmation", confirm && confirmation(confirm))
    |> put_if("x-tama-identity", if(method["result"] == "operation", do: ["operation_id"]))
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp json(schema), do: %{"application/json" => %{"schema" => schema}}

  defp tag("/1.0/" <> rest), do: rest |> String.split("/") |> hd()
  defp tag(_), do: "server"

  defp scope(%{"verb" => verb, "path" => path}) do
    cond do
      tag(path) in ["certificates", "cluster"] -> "incus.native.admin"
      path == "/1.0" and verb in ["PUT", "PATCH"] -> "incus.native.admin"
      verb == "GET" -> "incus.native.read"
      verb == "DELETE" -> "incus.native.delete"
      true -> "incus.native.write"
    end
  end

  # `confirm` repeats the last path parameter, or the literal `server`.
  defp confirm_target(method, %{"confirm" => %{"param" => param} = target}) do
    if param in method["params"],
      do: target,
      else: throw({:generator, "#{method["name"]}: confirm names unknown parameter #{param}"})
  end

  defp confirm_target(_method, %{"confirm" => target}), do: target

  defp confirm_target(method, _) do
    case path_params(method) do
      [] -> %{"value" => "server"}
      params -> %{"param" => List.last(params)}
    end
  end

  defp confirmation(%{"param" => param}),
    do: %{"field" => "confirm", "description" => "the exact value of `#{param}`"}

  defp confirmation(%{"value" => value}),
    do: %{"field" => "confirm", "description" => "the literal `#{value}`"}

  defp path_params(method) do
    for [_, name] <- Regex.scan(~r/\{([^}]+)\}/, method["path"]),
        name in method["params"],
        do: name
  end

  defp etag(%{"result" => "empty_sync"}), do: "required"
  defp etag(%{"conditional" => true}), do: "required"
  defp etag(%{"verb" => verb}) when verb in ["PUT", "PATCH"], do: "optional"
  defp etag(_), do: "none"

  defp description(method, upstream, etag) do
    route = method["verb"] <> " " <> method["path"] <> query(method["query"])

    facts =
      [
        "Native method `#{method["name"]}`: `#{route}`.",
        result_fact(method["result"]),
        extension_fact(List.wrap(method["extension"])),
        guard_fact(method["guards"]),
        if(etag == "required", do: "Requires `etag`, sent as If-Match.")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    case upstream do
      text when is_binary(text) and text != "" -> String.trim(text) <> "\n\n" <> facts
      _ -> facts
    end
  end

  defp query(query) when map_size(query) == 0, do: ""

  defp query(query),
    do:
      "?" <>
        (query |> Enum.sort() |> Enum.map_join("&", fn {key, value} -> "#{key}=#{value}" end))

  defp result_fact("operation"),
    do:
      "Result kind `operation`: returns the native operation identity at once, without waiting for it to finish."

  defp result_fact(kind), do: "Result kind `#{kind}`."

  defp extension_fact([]), do: nil

  defp extension_fact(extensions),
    do: "Requires API extension " <> Enum.map_join(extensions, ", ", &"`#{&1}`") <> "."

  defp guard_fact([]), do: nil

  defp guard_fact(guards) do
    "Field guards: " <>
      Enum.map_join(guards, "; ", fn
        %{"field" => field, "equals" => value} ->
          "`#{field}` must be `#{inspect(value)}`"

        %{"field" => field, "extension" => extension} ->
          "`#{field}` requires `#{extension}`"
      end) <> "."
  end

  # Input

  defp input(method, confirm, etag) do
    collisions = Enum.filter(method["params"], &(&1 in @reserved))

    if collisions != [],
      do: throw({:generator, "#{method["name"]}: parameter #{hd(collisions)} is reserved"})

    in_path = path_params(method)
    types = Map.get(method, "arg_types", %{})

    properties =
      Map.new(method["params"], &{&1, param(&1, argument_type(types[&1]), &1 in in_path)})
      |> put_if("project", if(project?(method), do: Fragments.project()))
      |> put_if("etag", if(etag != "none", do: etag_schema()))
      |> put_if("body", method["body"] && %{"$ref" => @ref <> method["body"] <> ".Input"})
      |> put_if("confirm", confirm && Fragments.confirm("Repeat #{confirm_text(confirm)}."))

    required =
      method["params"] ++
        if(method["body"], do: ["body"], else: []) ++
        if(etag == "required", do: ["etag"], else: []) ++
        if(confirm, do: ["confirm"], else: [])

    Fragments.object(properties, required)
  end

  defp confirm_text(confirm), do: confirmation(confirm)["description"]

  # An all-projects query and the unversioned root take no project.
  defp project?(%{"path" => path, "query" => query}),
    do: path != "/" and not Map.has_key?(query, "all-projects")

  defp etag_schema,
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 1024,
      "pattern" => @no_control,
      "description" => "ETag of the current resource, sent as If-Match."
    }

  defp argument_type("string"), do: nil
  defp argument_type(type), do: type

  defp param("filters", _, _),
    do: %{
      "type" => "array",
      "maxItems" => 128,
      "items" => %{"type" => "string", "maxLength" => 1024},
      "description" => "Native filter expressions, each `key=value`; may be empty."
    }

  defp param(name, "int", _),
    do: %{
      "type" => "integer",
      "minimum" => 0,
      "maximum" => 3600,
      "description" => "Query value `#{name}`, in seconds."
    }

  defp param(name, "bool", _),
    do: %{"type" => "boolean", "description" => "Query flag `#{name}`."}

  defp param(name, nil, true),
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 1024,
      "description" => "Path parameter `{#{name}}` of the native route."
    }

  defp param(name, nil, false),
    do: %{
      "type" => "string",
      "maxLength" => 1024,
      "description" => "Query value `#{name}`; may be empty."
    }

  defp param(name, type, _),
    do: throw({:generator, "parameter #{name} has unknown argument type #{inspect(type)}"})

  # Output: the bounded native envelope for the method's result kind.

  defp output(%{"result" => "operation"}) do
    Fragments.object(
      %{
        "kind" => kind("operation"),
        "operation_id" => %{"type" => "string", "description" => "Native operation UUID."},
        "operation" => %{"$ref" => @ref <> "Operation"}
      },
      ["kind", "operation_id", "operation"]
    )
  end

  defp output(%{"result" => "empty_sync"}),
    do: Fragments.object(%{"kind" => kind("empty_sync"), "etag" => result_etag()}, ["kind"])

  defp output(%{"result" => result} = method) do
    metadata = metadata(result, method["model"])
    required = if result == "sync", do: ["kind"], else: ["kind", "metadata"]

    Fragments.object(
      %{"kind" => kind(result), "metadata" => metadata, "etag" => result_etag()},
      required
    )
  end

  defp kind(kind), do: %{"type" => "string", "enum" => [kind]}

  defp result_etag,
    do: %{"type" => "string", "description" => "Native ETag of the response, when it has one."}

  defp metadata("sync", nil), do: %{"description" => "Native sync metadata, when there is any."}
  defp metadata(kind, model) when kind in ["model", "sync"] and is_binary(model), do: ref(model)

  defp metadata(kind, model) when kind in ["list", "grouped_list"] and is_binary(model),
    do: %{"type" => "array", "items" => ref(model)}

  defp metadata(kind, _) when kind in ["names", "strings"],
    do: %{"type" => "array", "items" => %{"type" => "string"}}

  defp metadata(kind, _) when kind in ["project_names", "project_urls"],
    do: %{
      "type" => "object",
      "additionalProperties" => %{"type" => "array", "items" => %{"type" => "string"}},
      "description" => "Names grouped by project."
    }

  defp metadata(kind, model),
    do: throw({:generator, "unknown result kind #{inspect(kind)} (model #{inspect(model)})"})

  defp ref(model), do: %{"$ref" => @ref <> model}

  # Components: every model referenced by an exported operation, transitively.
  # `<Model>` is the result form and allows unknown fields; `<Model>.Input` is
  # the body form, which allows none and omits denylisted fields.

  defp components(exported, context) do
    exported
    |> Enum.flat_map(&refs/1)
    |> Enum.uniq()
    |> expand(%{"Error" => Fragments.error_schema()}, context)
  end

  defp expand([], done, _context), do: done

  defp expand([name | rest], done, context) do
    if Map.has_key?(done, name) do
      expand(rest, done, context)
    else
      schema = component(name, context)
      expand(refs(schema) ++ rest, Map.put(done, name, schema), context)
    end
  end

  defp refs(%{} = map) do
    Enum.flat_map(map, fn
      {"$ref", @ref <> name} -> [name]
      {_, value} -> refs(value)
    end)
  end

  defp refs(list) when is_list(list), do: Enum.flat_map(list, &refs/1)
  defp refs(_), do: []

  defp component(name, context) do
    {model, mode} =
      case String.split(name, ".Input") do
        [model, ""] -> {model, :input}
        [model] -> {model, :result}
      end

    case context.models[model] do
      %{"kind" => "struct", "fields" => fields} ->
        struct(model, fields, mode, context)

      %{"underlying" => underlying} when mode == :result ->
        type(underlying, mode, context) |> describe(context.definitions[model])

      _ ->
        throw({:generator, "#{name} is not a known struct model"})
    end
  end

  defp struct(model, fields, mode, context) do
    definition = context.definitions[model] || %{}
    denied = if mode == :input, do: Map.get(context.denied, model, MapSet.new()), else: []

    properties =
      for %{"name" => field, "type" => type} <- fields, field not in denied, into: %{} do
        {field, type(type, mode, context) |> describe(get_in(definition, ["properties", field]))}
      end

    schema = %{"type" => "object", "properties" => properties}
    schema = if mode == :input, do: Map.put(schema, "additionalProperties", false), else: schema
    describe(schema, definition)
  end

  # Upstream text only: a description (or title) is attached, nothing else.
  defp describe(%{"$ref" => _} = schema, _), do: schema

  defp describe(schema, %{} = upstream) do
    case upstream["description"] || upstream["title"] do
      text when is_binary(text) and text != "" ->
        Map.put(schema, "description", String.trim(text))

      _ ->
        schema
    end
  end

  defp describe(schema, _), do: schema

  # Go types whose zero value is nil (pointers, slices and maps) allow null.
  defp type("*" <> type, mode, context), do: nullable(type(type, mode, context))

  defp type(bytes, _, _) when bytes in ["[]byte", "[]uint8"],
    do: %{"type" => ["string", "null"], "description" => "Base64-encoded bytes."}

  defp type("[]" <> type, mode, context),
    do: %{"type" => ["array", "null"], "items" => type(type, mode, context)}

  defp type("map[" <> rest, mode, context) do
    [key, value] = String.split(rest, "]", parts: 2)

    if key == "string" or get_in(context.models, [key, "underlying"]) == "string",
      do: %{"type" => ["object", "null"], "additionalProperties" => type(value, mode, context)},
      else: throw({:generator, "unknown Go map key type #{key}"})
  end

  defp type("string", _, _), do: %{"type" => "string"}
  defp type("bool", _, _), do: %{"type" => "boolean"}
  defp type(type, _, _) when type in @integers, do: %{"type" => "integer"}
  defp type(type, _, _) when type in @unsigned, do: %{"type" => "integer", "minimum" => 0}
  defp type(type, _, _) when type in ["float32", "float64"], do: %{"type" => "number"}
  defp type("any", _, _), do: %{}

  defp type("time.Time", _, _),
    do: %{"type" => "string", "description" => "RFC 3339 date and time."}

  defp type(type, mode, context) do
    case context.models[type] do
      %{"kind" => "struct"} when mode == :input -> %{"$ref" => @ref <> type <> ".Input"}
      %{"kind" => "struct"} -> ref(type)
      %{"kind" => "alias", "underlying" => underlying} -> type(underlying, mode, context)
      _ -> throw({:generator, "unknown Go type #{inspect(type)}"})
    end
  end

  defp nullable(%{"$ref" => _} = schema), do: %{"oneOf" => [schema, %{"type" => "null"}]}

  defp nullable(%{"type" => type} = schema),
    do: %{schema | "type" => Enum.uniq(List.wrap(type) ++ ["null"])}

  defp nullable(schema), do: schema

  # Upstream text, joined on verb plus the path with placeholders normalized.
  # A method with a recursion query prefers the matching `?recursion=N` entry.

  defp upstream_index(upstream) do
    for {path, item} <- Map.get(upstream, "paths") || %{},
        is_map(item),
        {verb, operation} <- item,
        is_map(operation),
        into: %{} do
      {{String.upcase(verb), normalize(path)}, Map.take(operation, ["summary", "description"])}
    end
  end

  defp upstream_text(method, index) do
    path = normalize(method["path"])

    variants =
      case method["query"] do
        %{"recursion" => depth} -> [path <> "?recursion=" <> depth, path]
        _ -> [path]
      end

    text = Enum.find_value(variants, %{}, &Map.get(index, {method["verb"], &1}))

    Map.filter(text, fn {_, value} -> is_binary(value) and String.trim(value) != "" end)
    |> Map.new(fn {key, value} -> {key, String.trim(value)} end)
  end

  defp normalize(path), do: String.replace(path, ~r/\{[^}]+\}/, "{}")
end
