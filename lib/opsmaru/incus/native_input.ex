defmodule Opsmaru.Incus.NativeInput do
  @moduledoc false
  alias Opsmaru.Incus.{Error, NativeConfig}
  @external_resource Path.expand("../../../priv/incus/models.json", __DIR__)
  @schemas Jason.decode!(File.read!(@external_resource))["models"]

  # Explicit typed input projection; ordinary Model.decode remains lossless.
  # Callers validate their byte/count budgets before entering this helper.
  def cast(type, value) do
    normalize(type, value)
  rescue
    _ -> {:error, %Error{kind: :invalid_native_input}}
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

  defp normalize("map[string]" <> type, value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      case {is_binary(key), normalize(type, item)} do
        {true, {:ok, normalized}} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp normalize(type, nil) when type in ["[]byte", "[]uint8"], do: {:ok, nil}

  defp normalize(type, value) when type in ["[]byte", "[]uint8"] and is_binary(value) do
    with {:ok, bytes} <- Base.decode64(value), do: {:ok, Base.encode64(bytes)}
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

  defp normalize(type, value)
       when type in ~w(int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64) do
    value = if is_nil(value), do: 0, else: value
    unsigned = String.starts_with?(type, "uint")
    digits = type |> String.trim_leading("u") |> String.trim_leading("int")
    bits = if digits == "", do: 64, else: String.to_integer(digits)
    lower = if unsigned, do: 0, else: -Integer.pow(2, bits - 1)
    upper = Integer.pow(2, if(unsigned, do: bits, else: bits - 1)) - 1

    if is_integer(value) and value >= lower and value <= upper, do: {:ok, value}, else: :error
  end

  defp normalize(type, value) when type in ["float32", "float64"] do
    value = if is_nil(value), do: 0, else: value

    if is_number(value) do
      native_float(type, value)
    else
      :error
    end
  end

  defp normalize("time.Time", nil), do: {:ok, "0001-01-01T00:00:00Z"}

  defp normalize("time.Time", value) when is_binary(value) do
    with {:ok, _, _} <- DateTime.from_iso8601(value) do
      normalized =
        value
        |> String.replace(",", ".")
        |> String.replace(~r/(\.\d*?[1-9])0+(Z|[+-]\d\d:\d\d)$/, "\\1\\2")
        |> String.replace(~r/\.0+(Z|[+-]\d\d:\d\d)$/, "\\1")
        |> String.replace(~r/\+00:00$/, "Z")

      {:ok, normalized}
    end
  end

  defp normalize(type, value) when type in ["any", "interface{}"],
    do: {:ok, native_any(value)}

  defp normalize("json.RawMessage", value), do: {:ok, value}

  defp normalize(type, value) do
    case @schemas[type] do
      %{"kind" => "struct", "fields" => fields} when is_map(value) or is_nil(value) ->
        normalize_fields(type, fields, value || %{})

      %{"underlying" => underlying, "kind" => kind} when kind != "struct" ->
        normalize(underlying, value)

      _ ->
        :error
    end
  end

  defp native_float("float32", value) do
    <<float::float-32>> = <<value::float-32>>
    {:ok, float}
  end

  defp native_float("float64", value), do: {:ok, value / 1}

  defp native_any(value) when is_number(value), do: value / 1
  defp native_any(value) when is_list(value), do: Enum.map(value, &native_any/1)

  defp native_any(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, native_any(item)} end)

  defp native_any(value), do: value

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
      Regex.scan(~r/^\s*(\w+)\s+`yaml:/m, source, capture: :all_but_first) |> List.flatten()

    String.contains?(source, "json:\"#{key},omitempty\"") or
      Enum.any?(embedded, &optional?(&1, key))
  end
end
