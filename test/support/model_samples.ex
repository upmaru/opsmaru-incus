defmodule Opsmaru.TestSupport.ModelSamples do
  @moduledoc """
  Schema-driven samples over the pinned model catalogue. Every field gets a typed
  non-zero value and nested structs, pointers, lists and maps are populated at
  every depth, so no generated collection is empty. A field whose type would
  recurse into one of its own ancestors (the only cycle is a GPU card's SR-IOV
  virtual functions) is left out rather than sent empty. Samples are fixture data
  compared with the pinned Go DTOs, not defaults.
  """
  @external_resource Path.expand("../../priv/incus/models.json", __DIR__)
  @models Jason.decode!(File.read!(@external_resource))["models"]

  def fields(model), do: @models[model]["fields"] || []

  # Struct models become maps; alias models (lists or maps) take their underlying type.
  def generate(model), do: generate(model, MapSet.new())

  defp generate(model, ancestors) do
    ancestors = MapSet.put(ancestors, model)

    case @models[model] do
      %{"kind" => "alias", "underlying" => underlying} ->
        value(underlying, String.downcase(model), ancestors)

      _ ->
        for field <- fields(model),
            not MapSet.member?(ancestors, base(field["type"])),
            into: %{},
            do: {field["name"], value(field["type"], field["name"], ancestors)}
    end
  end

  # The named type a field ultimately holds, through pointers, lists and map values.
  defp base("*" <> type), do: base(type)
  defp base("[]" <> type), do: base(type)
  defp base("map[" <> rest), do: rest |> String.split("]", parts: 2) |> List.last() |> base()
  defp base(type), do: type

  defp value("*" <> type, name, ancestors), do: value(type, name, ancestors)
  defp value("[]string", name, _), do: ["fixture-" <> name]
  defp value("[]" <> type, name, ancestors), do: [value(type, name, ancestors)]

  # Maps keyed by string or a named string type, e.g. map[MetadataConfigGroupName]Group.
  defp value("map[" <> rest, name, ancestors) do
    [_key, type] = String.split(rest, "]", parts: 2)
    %{"fixture" => value(type, name, ancestors)}
  end

  defp value("string", name, _), do: "fixture-" <> name
  defp value("bool", _, _), do: true
  defp value(type, _, _) when type in ~w(int int64 uint16 uint64), do: 7
  defp value("float64", _, _), do: 1.5
  defp value("time.Time", _, _), do: "2026-10-22T12:00:00Z"
  defp value("ConfigMap", _, _), do: %{"user.fixture" => "value"}
  defp value(type, _, ancestors) when is_map_key(@models, type), do: generate(type, ancestors)
end
