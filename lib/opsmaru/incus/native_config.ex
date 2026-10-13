defmodule Opsmaru.Incus.NativeConfig do
  @moduledoc """
  Explicit pinned ConfigMap/DevicesMap JSON and YAML coercion, separate from
  lossless models.

  String, boolean, number and null config values become native strings. JSON
  numbers use the official decoder's float64 semantics, including integer
  precision loss. YAML decoding is delegated to `Opsmaru.Incus.NativeYaml`,
  a deliberately small strict-subset decoder that matches the native
  go-yaml v4 result on every accepted input and reports
  `{:error, :invalid_native_config}` for everything outside the subset
  (explicit tags, directives, extra documents, sequences outside merge
  lists, nesting deeper than four levels, non-string keys, timestamps,
  ...). Decoding into an existing map merges keys; a null document resets
  the target while an absent document leaves it untouched. Device updates
  merge individual properties. Inputs and results are bounded to 1 MiB.
  No backend, filesystem state or global configuration is involved.
  """
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.NativeYaml

  @limit 1_048_576

  def from_json(type, json, existing \\ nil) do
    with true <- type in ["ConfigMap", "DevicesMap"],
         true <- is_binary(json) and byte_size(json) <= @limit,
         {:ok, data} <- Jason.decode(json),
         :ok <- existing_map(type, existing),
         true <- existing_bytes(existing) <= @limit,
         {:ok, result} <- merge(type, data, existing),
         {:ok, encoded} <- Jason.encode(result),
         true <- byte_size(encoded) <= @limit do
      {:ok, result}
    else
      _ -> {:error, %Error{kind: :invalid_native_config}}
    end
  rescue
    _ -> {:error, %Error{kind: :invalid_native_config}}
  end

  def from_yaml(type, yaml, existing \\ nil) do
    with true <- type in ["ConfigMap", "DevicesMap"],
         true <- is_binary(yaml) and byte_size(yaml) <= @limit,
         :ok <- existing_map(type, existing),
         true <- existing_bytes(existing) <= @limit,
         {:ok, result} <- NativeYaml.decode(yaml_type(type), yaml, existing),
         {:ok, encoded} <- Jason.encode(result),
         true <- byte_size(encoded) <= @limit do
      {:ok, result}
    else
      _ -> {:error, %Error{kind: :invalid_native_config}}
    end
  end

  defp yaml_type("ConfigMap"), do: :config_map
  defp yaml_type("DevicesMap"), do: :devices_map

  # ---------------------------------------------------------------------
  # Shared existing-target validation (JSON and YAML paths).
  # ---------------------------------------------------------------------

  defp existing_map(_, nil), do: :ok

  defp existing_map("ConfigMap", value) when is_map(value) do
    if map_size(value) <= 4096 and
         Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end),
       do: :ok,
       else: :error
  end

  defp existing_map("DevicesMap", value) when is_map(value) do
    if map_size(value) <= 4096 and
         Enum.all?(value, fn {key, item} ->
           is_binary(key) and existing_map("ConfigMap", item) == :ok
         end), do: :ok, else: :error
  end

  defp existing_map(_, _), do: :error

  defp existing_bytes(nil), do: 0
  defp existing_bytes(value) when is_binary(value), do: byte_size(value)

  defp existing_bytes(value) when is_map(value),
    do:
      Enum.reduce(value, 0, fn {key, item}, total ->
        total + byte_size(key) + existing_bytes(item)
      end)

  # ---------------------------------------------------------------------
  # JSON path.
  # ---------------------------------------------------------------------

  defp merge(_, nil, existing), do: {:ok, existing}

  defp merge(type, data, existing) when is_map(data) and map_size(data) <= 4096 do
    Enum.reduce_while(data, {:ok, existing || %{}}, fn {key, value}, {:ok, acc} ->
      result = if type == "ConfigMap", do: scalar(value), else: device(value, acc[key])

      case result do
        {:ok, native} when is_binary(key) -> {:cont, {:ok, Map.put(acc, key, native)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp merge(_, _, _), do: :error

  defp device(value, existing) when is_map(value), do: merge("ConfigMap", value, existing)
  defp device(_, _), do: :error
  defp scalar(nil), do: {:ok, ""}
  defp scalar(true), do: {:ok, "true"}
  defp scalar(false), do: {:ok, "false"}
  defp scalar(value) when is_binary(value), do: {:ok, value}

  defp scalar(value) when is_number(value) do
    float = value / 1

    cond do
      float >= -9_223_372_036_854_775_808 and float < 9_223_372_036_854_775_808 and
          float == trunc(float) ->
        {:ok, Integer.to_string(trunc(float))}

      float == 9_223_372_036_854_775_808 and arm64?() ->
        # Go's out-of-range float64 -> int64 conversion is architecture-specific.
        # ARM64 saturates to MaxInt64, whose float64 roundtrip equals 2^63;
        # AMD64 yields MinInt64 and therefore uses the scientific branch.
        {:ok, "9223372036854775807"}

      true ->
        {:ok, go_float(float)}
    end
  end

  defp scalar(_), do: :error

  # Native float64/number stringification shared with `NativeYaml`.
  @doc false
  def native_string(value) when is_number(value), do: scalar(value)

  defp arm64?,
    do:
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.starts_with?(["aarch64", "arm64"])

  # strconv.FormatFloat('g', -1, 64): shortest representation; scientific
  # notation below 1e-4 or at/above 1e6, with signed two-digit exponents.
  # Shared by the JSON path and `NativeYaml`'s float64 stringification.
  @doc false
  @spec go_float(float()) :: String.t()
  def go_float(float) do
    case String.split(:erlang.float_to_binary(float, [:short]), "e") do
      [decimal] ->
        if abs(float) >= 1_000_000 do
          {sign, decimal} =
            if String.starts_with?(decimal, "-"),
              do: {"-", String.trim_leading(decimal, "-")},
              else: {"", decimal}

          [whole, fraction] = String.split(decimal, ".")
          digits = whole <> fraction

          sign <>
            binary_part(digits, 0, 1) <>
            "." <>
            binary_part(digits, 1, byte_size(digits) - 1) <>
            "e+" <> String.pad_leading(Integer.to_string(byte_size(whole) - 1), 2, "0")
        else
          decimal
        end

      [mantissa, exponent] ->
        exponent = String.to_integer(exponent)
        mantissa = String.replace_suffix(mantissa, ".0", "")

        if exponent < -4 or exponent >= 6 do
          mantissa <>
            "e" <>
            if(exponent < 0, do: "-", else: "+") <>
            String.pad_leading(Integer.to_string(abs(exponent)), 2, "0")
        else
          {sign, mantissa} =
            if String.starts_with?(mantissa, "-"),
              do: {"-", String.trim_leading(mantissa, "-")},
              else: {"", mantissa}

          digits = String.replace(mantissa, ".", "")
          point = exponent + 1

          sign <>
            cond do
              point <= 0 ->
                "0." <> String.duplicate("0", -point) <> digits

              point >= byte_size(digits) ->
                digits <> String.duplicate("0", point - byte_size(digits))

              true ->
                binary_part(digits, 0, point) <>
                  "." <> binary_part(digits, point, byte_size(digits) - point)
            end
        end
    end
  end
end
