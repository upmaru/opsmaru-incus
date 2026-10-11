defmodule Opsmaru.Incus.PreseedConfig do
  @moduledoc false
  alias Opsmaru.Incus.{Error, Model, NativeConfig}
  @external_resource Path.expand("../../../priv/incus/models.json", __DIR__)
  @schemas Jason.decode!(File.read!(@external_resource))["models"]
  @collections ~w(networks storage_pools storage_volumes profiles projects certificates cluster_groups)

  def prepare(value, limit) do
    with data when is_map(data) <- Model.encode(value),
         {:ok, json} <- Jason.encode(data),
         true <- byte_size(json) <= limit,
         {:ok, data} <- normalize("InitPreseed", data),
         true <- Enum.sum(Enum.map(@collections, &length(data[&1] || []))) <= 128,
         {:ok, _} <- Model.decode("InitPreseed", data) do
      {:ok, data}
    else
      _ -> {:error, %Error{kind: :invalid_preseed}}
    end
  rescue
    _ -> {:error, %Error{kind: :invalid_preseed}}
  end

  def project(item), do: default(item["Project"], "default")
  def volume_type(item), do: default(item["type"], "custom")
  defp default(value, fallback) when value in [nil, ""], do: fallback
  defp default(value, _), do: value

  def project_body(type, value) do
    {:ok, data} = normalize(type, value)
    data
  end

  defp normalize(type, value) when type in ["ConfigMap", "DevicesMap"],
    do: NativeConfig.from_json(type, Jason.encode!(value))

  defp normalize("*" <> _, nil), do: {:ok, nil}
  defp normalize("*" <> type, value), do: normalize(type, value)
  defp normalize("map[string]" <> _, nil), do: {:ok, nil}

  defp normalize("map[string]string", value) when is_map(value) do
    if Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end),
      do: {:ok, value},
      else: :error
  end

  defp normalize("[]" <> _, nil), do: {:ok, nil}

  defp normalize("[]" <> type, values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize(type, value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp normalize(type, value) when type in ["string", "bool"] do
    value = if is_nil(value), do: if(type == "string", do: "", else: false), else: value

    if (type == "string" and is_binary(value)) or (type == "bool" and is_boolean(value)),
      do: {:ok, value},
      else: :error
  end

  defp normalize(type, value) do
    case @schemas[type] do
      %{"kind" => "struct", "fields" => fields} when is_map(value) or is_nil(value) ->
        normalize_fields(type, fields, value || %{})

      _ ->
        :error
    end
  end

  defp normalize_fields(type, fields, value) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      # Native encoding/json accepts case-insensitive field names. Reject
      # ambiguous aliases rather than selecting a map's unspecified order.
      keys =
        Enum.filter(Map.keys(value), &(String.downcase(&1) == String.downcase(field["name"])))

      case keys do
        [_first, _second | _] ->
          {:halt, :error}

        _ ->
          input = if keys == [], do: nil, else: value[hd(keys)]

          case normalize(field["type"], input) do
            {:ok, data} -> {:cont, {:ok, Map.put(acc, field["name"], data)}}
            error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, data} -> {:ok, omit_empty(data, type)}
      error -> error
    end
  end

  defp omit_empty(data, type) do
    Map.reject(data, fn {key, value} ->
      value in [nil, "", false, 0, [], %{}] and optional?(type, key)
    end)
  end

  defp optional?(type, key) do
    source = @schemas[type]["underlying"]

    embedded =
      Regex.scan(~r/^\s*(\w+) `yaml:/m, source, capture: :all_but_first) |> List.flatten()

    String.contains?(source, "json:\"#{key},omitempty\"") or
      Enum.any?(embedded, &optional?(&1, key))
  end
end
