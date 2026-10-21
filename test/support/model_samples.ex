defmodule Opsmaru.TestSupport.ModelSamples do
  @moduledoc """
  Schema-driven samples over the pinned model catalogue. Every field gets a typed
  non-zero value; nested structs, pointers, lists and maps recurse, bounded in
  depth. Samples are fixture data compared with the pinned Go DTOs, not defaults.
  """
  @external_resource Path.expand("../../priv/incus/models.json", __DIR__)
  @models Jason.decode!(File.read!(@external_resource))["models"]

  def fields(model), do: @models[model]["fields"]

  def generate(model, depth \\ 0) do
    Map.new(fields(model), fn field ->
      {field["name"], value(field["type"], field["name"], depth)}
    end)
  end

  defp value("*" <> type, name, depth), do: value(type, name, depth)
  defp value("[]string", name, _), do: ["fixture-" <> name]

  defp value("[]" <> type, name, depth),
    do: if(depth < 3, do: [value(type, name, depth + 1)], else: [])

  defp value("map[string]" <> type, name, depth),
    do: if(depth < 3, do: %{"fixture" => value(type, name, depth + 1)}, else: %{})

  defp value("string", name, _), do: "fixture-" <> name
  defp value("bool", _, _), do: true
  defp value(type, _, _) when type in ~w(int int64 uint64), do: 7
  defp value("ConfigMap", _, _), do: %{"user.fixture" => "value"}
  defp value(type, _, depth) when is_map_key(@models, type), do: generate(type, depth + 1)
end
