defmodule Opsmaru.TestSupport.ProfileChecks do
  @moduledoc false
  # Structural checks of a `tama-operations/1` document against the profile
  # rules (tama-dex docs/tama-operations-profile.md), independent of tama_dex.
  # `issues/1` returns `[]` for a conforming document.
  alias Opsmaru.Incus.Operations.Schema

  @operation_fields ~w(operationId summary description tags deprecated requestBody responses
                       x-tama-scopes x-tama-destructive x-tama-confirmation x-tama-bounds
                       x-tama-identity)
  @document_tama ~w(x-tama-profile x-tama-source)
  @ref "#/components/schemas/"

  def issues(document) do
    paths = Map.get(document, "paths", %{})
    components = get_in(document, ["components", "schemas"]) || %{}
    ids = for {_, %{"post" => %{"operationId" => id}}} <- paths, do: id

    document(document, paths, components) ++
      for(id <- ids -- Enum.uniq(ids), do: "duplicate operationId #{id}") ++
      Enum.flat_map(paths, fn {path, item} -> path_item(path, item, components) end)
  end

  defp document(document, paths, components) do
    checks([
      {Map.get(document, "openapi", "") =~ ~r/\A3\.1\.\d+\z/, "openapi is not 3.1.x"},
      {Map.get(document, "jsonSchemaDialect") in [
         nil,
         "https://spec.openapis.org/oas/3.1/dialect/base",
         "https://json-schema.org/draft/2020-12/schema"
       ], "unknown jsonSchemaDialect"},
      {is_binary(get_in(document, ["info", "title"])), "info.title is missing"},
      {is_binary(get_in(document, ["info", "version"])), "info.version is missing"},
      {document["x-tama-profile"] == "tama-operations/1", "x-tama-profile is wrong"},
      {is_binary(document["x-tama-source"]) and
         document["x-tama-source"] =~ ~r/\A[a-z][a-z0-9_]{0,63}\z/, "x-tama-source is invalid"},
      {not Map.has_key?(document, "webhooks"), "webhooks present"},
      {tama_keys(document) -- @document_tama == [], "unknown document x-tama-* key"},
      {map_size(paths) in 1..1024, "operation count is out of range"},
      {byte_size(Jason.encode!(document)) <= 4 * 1024 * 1024, "document exceeds 4 MiB"},
      {Enum.all?(Map.keys(components), &(&1 =~ ~r/\A[a-zA-Z0-9._-]+\z/)),
       "invalid component name"}
    ]) ++ Enum.flat_map(components, fn {name, schema} -> schema("component #{name}", schema) end)
  end

  defp path_item("/operations/" <> id = path, %{"post" => operation} = item, components)
       when map_size(item) == 1 do
    input = get_in(operation, ["requestBody", "content", "application/json", "schema"])
    responses = Map.get(operation, "responses", %{})
    success = get_in(responses, ["200", "content", "application/json", "schema"])
    failure = get_in(responses, ["default", "content", "application/json", "schema"])

    checks(
      [
        {operation["operationId"] == id, "operationId differs from the path"},
        {id =~ ~r/\A[a-z][a-z0-9_]{0,127}\z/, "operationId is invalid"},
        {text?(operation["summary"], 120), "summary is missing or too long"},
        {text?(operation["description"], 4096), "description is missing or too long"},
        {tags?(Map.get(operation, "tags", [])), "tags are invalid"},
        {extra_fields(operation) == [], "unexpected fields #{inspect(extra_fields(operation))}"},
        {operation["requestBody"]["required"] == true, "requestBody is not required"},
        {media?(operation["requestBody"]), "requestBody is not exactly application/json"},
        {is_map(input) and resolve(input, components)["type"] == "object",
         "input is not an object schema"},
        {Map.keys(responses) -- ["200", "default"] == [], "unexpected response keys"},
        {is_map(success) and media?(responses["200"]), "200 has no application/json schema"},
        {Enum.all?(Map.values(responses), &is_binary(&1["description"])),
         "a response has no description"},
        {not Map.has_key?(responses, "default") or
           (is_map(failure) and media?(responses["default"])),
         "default has no application/json schema"},
        {scopes?(operation["x-tama-scopes"]), "x-tama-scopes are invalid"},
        {is_boolean(operation["x-tama-destructive"]), "x-tama-destructive is not a boolean"},
        {confirmation?(operation["x-tama-confirmation"], resolve(input, components), components),
         "x-tama-confirmation does not name a required top-level string"},
        {bounds?(Map.get(operation, "x-tama-bounds", %{})), "x-tama-bounds are invalid"},
        {identity?(Map.get(operation, "x-tama-identity", []), [success, failure], components),
         "x-tama-identity names an undeclared property"},
        {opaque_bytes(operation) <= 16 * 1024, "opaque metadata exceeds 16 KiB"}
      ],
      path
    ) ++
      Enum.flat_map(
        [{"input", input}, {"200", success}, {"default", failure}],
        fn {label, schema} ->
          if is_map(schema),
            do: schema("#{path} #{label}", schema) ++ size(path, label, schema, components),
            else: []
        end
      )
  end

  defp path_item(path, _, _), do: ["#{path}: not exactly one post under /operations/{id}"]

  defp checks(list, prefix \\ nil) do
    for {ok?, message} <- list,
        not ok?,
        do: if(prefix, do: "#{prefix}: #{message}", else: message)
  end

  defp tama_keys(map), do: for({"x-tama-" <> _ = key, _} <- map, do: key)

  defp extra_fields(operation) do
    for {key, _} <- operation,
        key not in @operation_fields,
        not (String.starts_with?(key, "x-") and not String.starts_with?(key, "x-tama-")),
        do: key
  end

  defp opaque_bytes(operation) do
    operation
    |> Map.filter(fn {key, _} ->
      String.starts_with?(key, "x-") and not String.starts_with?(key, "x-tama-")
    end)
    |> Jason.encode!()
    |> byte_size()
  end

  defp text?(value, max), do: is_binary(value) and value != "" and String.length(value) <= max

  defp tags?(tags),
    do:
      is_list(tags) and length(tags) <= 16 and tags == Enum.uniq(tags) and
        Enum.all?(tags, &text?(&1, 64))

  defp media?(%{"content" => %{"application/json" => media} = content}),
    do: map_size(content) == 1 and Map.keys(media) == ["schema"]

  defp media?(_), do: false

  defp scopes?([_ | _] = scopes),
    do:
      scopes == Enum.uniq(scopes) and
        Enum.all?(scopes, &(is_binary(&1) and &1 =~ ~r/\A[A-Za-z0-9._:-]{1,128}\z/))

  defp scopes?(_), do: false

  defp confirmation?(nil, _, _), do: true

  defp confirmation?(%{"field" => field, "description" => description} = rule, input, components)
       when map_size(rule) == 2 do
    property = resolve(get_in(input, ["properties", field]) || %{}, components)

    text?(description, 256) and field in Map.get(input, "required", []) and
      property["type"] == "string"
  end

  defp confirmation?(_, _, _), do: false

  defp bounds?(bounds) when is_map(bounds),
    do:
      Enum.all?(bounds, fn {key, value} ->
        key =~ ~r/\A[a-z][a-z0-9_]{0,63}\z/ and is_integer(value) and value >= 0
      end)

  defp bounds?(_), do: false

  defp identity?(names, schemas, components) do
    declared =
      for schema <- schemas, is_map(schema), reduce: [] do
        acc -> acc ++ Map.keys(Map.get(resolve(schema, components), "properties", %{}))
      end

    is_list(names) and length(names) <= 8 and names == Enum.uniq(names) and
      names -- declared == []
  end

  # A schema that is only a `$ref` (plus annotations) is read through.
  defp resolve(%{"$ref" => @ref <> name}, components),
    do: resolve(Map.get(components, name, %{}), components)

  defp resolve(schema, _), do: schema

  # Every schema uses only keywords the library validator implements, has no
  # `$id`, and refers only into `#/components/schemas/`.
  defp schema(label, schema) do
    case unsupported(schema) do
      [] -> []
      keys -> ["#{label}: unsupported schema keywords #{inspect(Enum.uniq(keys))}"]
    end
  end

  defp unsupported(schema) when is_map(schema) do
    keys = for {key, _} <- schema, key not in Schema.keywords(), do: key

    bad_ref =
      case schema do
        %{"$ref" => @ref <> _} -> []
        %{"$ref" => other} -> ["$ref:" <> inspect(other)]
        _ -> []
      end

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

    keys ++ bad_ref ++ nested
  end

  defp unsupported(_), do: []

  defp size(path, label, schema, components) do
    bytes =
      schema
      |> referenced(components, MapSet.new())
      |> Enum.reduce(byte_size(Jason.encode!(schema)), fn name, total ->
        total + byte_size(Jason.encode!(components[name]))
      end)

    cond do
      Enum.any?(referenced(schema, components, MapSet.new()), &(not Map.has_key?(components, &1))) ->
        ["#{path} #{label}: unresolved $ref"]

      bytes > 256 * 1024 ->
        ["#{path} #{label}: schema with components is #{bytes} bytes (over 256 KiB)"]

      true ->
        []
    end
  end

  defp referenced(%{} = schema, components, seen) do
    Enum.reduce(schema, seen, fn
      {"$ref", @ref <> name}, seen ->
        if MapSet.member?(seen, name),
          do: seen,
          else: referenced(Map.get(components, name), components, MapSet.put(seen, name))

      {_, value}, seen ->
        referenced(value, components, seen)
    end)
  end

  defp referenced(list, components, seen) when is_list(list),
    do: Enum.reduce(list, seen, &referenced(&1, components, &2))

  defp referenced(_, _, seen), do: seen
end
