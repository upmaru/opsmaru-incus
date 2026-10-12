defmodule Opsmaru.Incus.Model do
  @moduledoc """
  Typed native model value backed by pinned official JSON field schemas.

  `decode/2` validates known field types without dropping optional/null or
  unknown fields. `data` is the lossless native map/list/scalar, not a workload
  abstraction. Native string keys avoid runtime atom creation. `encode/1`
  returns the native value for mutation bodies. Inventory presence alone is
  not evidence for model helpers or complete client coverage.
  """
  @external_resource Path.expand("../../../priv/incus/models.json", __DIR__)
  @schemas Jason.decode!(File.read!(@external_resource))["models"]
  @enforce_keys [:type, :data]
  defstruct [:type, :data]
  @type t :: %__MODULE__{type: String.t(), data: term()}

  def decode(type, data) when is_binary(type) do
    case Map.fetch(@schemas, type) do
      {:ok, schema} ->
        if valid_model?(schema, data),
          do: {:ok, %__MODULE__{type: type, data: data}},
          else: {:error, :invalid_model}

      :error ->
        {:error, :unknown_model}
    end
  end

  def encode(%__MODULE__{data: data}), do: data
  def encode(data), do: data
  def types, do: Map.keys(@schemas) |> Enum.sort()

  @writable_types ~w(Certificate ClusterMember ClusterGroup Image Instance InstanceSnapshot Network NetworkACL NetworkAddressSet NetworkForward NetworkIntegration NetworkLoadBalancer NetworkPeer NetworkZone NetworkZoneRecord Profile Project Server StoragePool StorageBucket StorageBucketKey StorageVolume StorageVolumeSnapshot)
  @doc "Select the pinned native writable DTO fields, retaining present nulls and omitting read-only/unknown fields."
  def writable(%__MODULE__{type: type, data: data})
      when type in @writable_types and is_map(data) do
    target = type <> "Put"
    fields = @schemas[target]["fields"] |> Enum.map(& &1["name"])
    decode(target, Map.take(data, fields))
  end

  def writable(_), do: {:error, :unsupported_model_helper}

  def writable_types, do: @writable_types

  @doc "Native Instance.IsActive semantics, including unknown status codes."
  def active?(%__MODULE__{type: "Instance", data: data}) when is_map(data),
    do: {:ok, (data["status_code"] || 0) not in [102, 112]}

  def active?(_), do: {:error, :unsupported_model_helper}

  @etag_fields %{
    "NetworkForward" => ~w(listen_address description config ports),
    "NetworkLoadBalancer" => ~w(listen_address description config backends ports),
    "NetworkPeer" => ~w(name description config),
    "StorageBucket" => ~w(name description config),
    "StorageBucketKey" => ~w(name description role access-key secret-key)
  }
  @doc "Native Etag input values; these privileged values are not the server's ETag header."
  def etag_values(%__MODULE__{type: type, data: data})
      when is_map_key(@etag_fields, type) and is_map(data),
      do:
        {:ok,
         Enum.map(@etag_fields[type], fn field ->
           if field in ~w(config ports backends), do: data[field], else: data[field] || ""
         end)}

  def etag_values(_), do: {:error, :unsupported_model_helper}

  defp valid_model?(_, nil), do: true

  defp valid_model?(%{"kind" => "struct", "fields" => fields}, data) when is_map(data),
    do:
      Enum.all?(fields, fn field ->
        not Map.has_key?(data, field["name"]) or valid?(field["type"], data[field["name"]])
      end)

  defp valid_model?(%{"kind" => "struct"}, _), do: false
  defp valid_model?(%{"underlying" => type}, data), do: valid?(type, data)

  defp valid?(_, nil), do: true
  defp valid?("*" <> type, data), do: valid?(type, data)

  defp valid?(type, data) when type in ["[]byte", "[]uint8"] and is_binary(data),
    do: match?({:ok, _}, Base.decode64(data))

  defp valid?("[]" <> type, data) when is_list(data), do: Enum.all?(data, &valid?(type, &1))
  defp valid?("[]" <> _, _), do: false

  defp valid?("map[string]" <> type, data) when is_map(data),
    do: Enum.all?(data, fn {key, value} -> is_binary(key) and valid?(type, value) end)

  defp valid?("map[string]" <> _, _), do: false

  defp valid?("map[" <> suffix, data) do
    case String.split(suffix, "]", parts: 2) do
      [key_type, type] ->
        get_in(@schemas, [key_type, "underlying"]) == "string" and
          valid?("map[string]" <> type, data)

      _ ->
        false
    end
  end

  defp valid?("string", data), do: is_binary(data)
  defp valid?("bool", data), do: is_boolean(data)

  defp valid?(type, data)
       when type in [
              "int",
              "int8",
              "int16",
              "int32",
              "int64",
              "uint",
              "uint8",
              "uint16",
              "uint32",
              "uint64"
            ],
       do: integer?(type, data)

  defp valid?(type, data) when type in ["float32", "float64"], do: is_number(data)
  defp valid?("time.Time", data), do: is_binary(data)

  defp valid?(type, data) do
    case Map.fetch(@schemas, type) do
      {:ok, schema} -> valid_model?(schema, data)
      # External transport/custom JSON types retain their native representation.
      :error -> true
    end
  end

  defp integer?(type, data) when is_integer(data) do
    unsigned = String.starts_with?(type, "uint")
    bits = type |> String.trim_leading("u") |> String.trim_leading("int")
    bits = if bits == "", do: 64, else: String.to_integer(bits)
    lower = if unsigned, do: 0, else: -Integer.pow(2, bits - 1)
    upper = Integer.pow(2, if(unsigned, do: bits, else: bits - 1)) - 1
    data >= lower and data <= upper
  end

  defp integer?(_, _), do: false
end

defimpl Inspect, for: Opsmaru.Incus.Model do
  def inspect(model, _), do: "#Opsmaru.Incus.Model<#{model.type} native data redacted>"
end
