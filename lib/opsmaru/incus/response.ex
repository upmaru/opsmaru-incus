defmodule Opsmaru.Incus.Response do
  @moduledoc "Native Incus envelope with lossless metadata/unknown fields and ETag."
  alias Opsmaru.Incus.{Error, Model, NativeInput}

  defstruct type: "",
            status: "",
            status_code: 0,
            operation: "",
            error_code: 0,
            error: "",
            metadata: nil,
            etag: "",
            http_status: nil,
            raw: %{},
            connection: nil,
            identity: nil

  @type t :: %__MODULE__{}

  @doc """
  Explicit typed JSON projection for native Response, ResponseRaw and ResponseType.

  Unlike the wire envelope decoder, arbitrary response-type strings and native
  null/default fields are accepted. Unknown fields are dropped. Response metadata
  retains decoded JSON numbers; ResponseRaw metadata uses native float64 numbers.
  This returns model data, never an accepted operation or authorized connection.

  Input/output are bounded to 1 MiB and input nesting to 64 levels. Duplicate
  object keys, ambiguous case aliases and non-ASCII envelope keys reject rather
  than emulate Go's ordered merging and Unicode field-name folding. ResponseRaw
  also rejects negative zero with an integer mantissa (including exponents),
  whose sign Jason discards. RawMessage
  whitespace/number spelling is not retained. Equality concerns parsed JSON for
  RawMessage and exact native float64 values for ResponseRaw metadata.
  """
  def decode_native(type, body)
      when type in ~w(Response ResponseRaw ResponseType) and is_binary(body) and
             byte_size(body) <= 1_048_576 do
    with {:ok, ordered} <- Jason.decode(body, objects: :ordered_objects),
         true <- native_shape?(ordered, 0),
         true <- native_keys?(ordered),
         true <- native_number_spelling?(type, body),
         {:ok, data} <- NativeInput.cast(type, native_value(ordered)),
         {:ok, encoded} when byte_size(encoded) <= 1_048_576 <- Jason.encode(data),
         {:ok, model} <- Model.decode(type, data) do
      {:ok, model}
    else
      _ -> native_model_error()
    end
  end

  def decode_native(_, _), do: native_model_error()

  defp native_shape?(_, depth) when depth > 64, do: false

  defp native_shape?(%Jason.OrderedObject{values: pairs}, depth) do
    keys = Enum.map(pairs, &elem(&1, 0))

    MapSet.size(MapSet.new(keys)) == length(keys) and
      Enum.all?(pairs, fn {_, value} -> native_shape?(value, depth + 1) end)
  end

  defp native_shape?(values, depth) when is_list(values),
    do: Enum.all?(values, &native_shape?(&1, depth + 1))

  defp native_shape?(_, _), do: true

  defp native_keys?(%Jason.OrderedObject{values: pairs}),
    do: Enum.all?(pairs, fn {key, _} -> String.to_charlist(key) |> Enum.all?(&(&1 < 128)) end)

  defp native_keys?(_), do: true

  defp native_number_spelling?("ResponseRaw", body) do
    # Consume complete strings first so a literal "-0" is never mistaken for
    # a numeric token. JSON syntax has already been validated by Jason.
    Regex.scan(~r/"(?:[^"\\]++|\\.)*+"|-0(?:[eE][+-]?\d+)?(?=[\s,\]}]|$)/s, body)
    |> Enum.all?(fn [token] -> String.starts_with?(token, "\"") end)
  end

  defp native_number_spelling?(_, _), do: true

  defp native_value(%Jason.OrderedObject{values: pairs}),
    do: Map.new(pairs, fn {key, value} -> {key, native_value(value)} end)

  defp native_value(values) when is_list(values), do: Enum.map(values, &native_value/1)
  defp native_value(value), do: value
  defp native_model_error, do: {:error, %Error{kind: :invalid_response_model}}

  def decode(body, status, headers) do
    with {:ok, raw} when is_map(raw) <- Jason.decode(body),
         true <- valid?(raw) do
      fields =
        for key <- [:type, :status, :status_code, :operation, :error_code, :error, :metadata],
            Map.has_key?(raw, Atom.to_string(key)),
            do: {key, raw[Atom.to_string(key)]}

      {:ok,
       struct!(__MODULE__, fields ++ [http_status: status, etag: headers["etag"] || "", raw: raw])}
    else
      _ -> {:error, :invalid_envelope}
    end
  end

  defp valid?(raw) do
    raw["type"] in ["sync", "async", "error"] and
      Enum.all?(
        ["status", "operation", "error"],
        &(not Map.has_key?(raw, &1) or is_binary(raw[&1]))
      ) and
      Enum.all?(
        ["status_code", "error_code"],
        &(not Map.has_key?(raw, &1) or is_integer(raw[&1]))
      )
  end

  @doc "Accepted async envelopes are not completed operations."
  def accepted?(%__MODULE__{type: "async"}), do: true
  def accepted?(_), do: false

  @doc "Extract native map metadata without modifying the originating response."
  def metadata_as_map(%__MODULE__{metadata: nil}), do: {:ok, %{}}

  def metadata_as_map(%__MODULE__{metadata: value}) when is_map(value) do
    with {:ok, native} <- native_payload(value),
         {:ok, metadata} <- NativeInput.cast("map[string]any", native) do
      {:ok, metadata || %{}}
    else
      _ -> metadata_error()
    end
  end

  def metadata_as_map(_), do: metadata_error()

  @doc "Extract native string-slice metadata; native null retains the initialized empty slice."
  def metadata_as_string_slice(%__MODULE__{metadata: nil}), do: {:ok, []}

  def metadata_as_string_slice(%__MODULE__{metadata: values}) when is_list(values) do
    with {:ok, native} <- native_payload(values),
         true <- Enum.all?(native, &(is_binary(&1) or is_nil(&1))) do
      {:ok, Enum.map(native, &(&1 || ""))}
    else
      _ -> metadata_error()
    end
  end

  def metadata_as_string_slice(_), do: metadata_error()

  @doc "Explicit typed native projection; ordinary response/model decoding remains lossless."
  def metadata_as_model(%__MODULE__{metadata: data}, type) when is_binary(type) do
    with {:ok, native} <- native_payload(data),
         {:ok, normalized} <- NativeInput.cast(type, native),
         {:ok, model} <- Model.decode(type, normalized) do
      {:ok, model}
    else
      _ -> metadata_error()
    end
  end

  def metadata_as_model(_, _), do: metadata_error()
  def metadata_as_operation(response), do: metadata_as_model(response, "Operation")

  defp native_payload(data) do
    with {:ok, bytes} when byte_size(bytes) <= 1_048_576 <- Jason.encode(Model.encode(data)),
         {:ok, native} <- Jason.decode(bytes) do
      {:ok, native}
    else
      _ -> metadata_error()
    end
  end

  defp metadata_error, do: {:error, %Error{kind: :invalid_metadata}}
end

defimpl Inspect, for: Opsmaru.Incus.Response do
  def inspect(response, _),
    do: "#Opsmaru.Incus.Response<#{response.type} HTTP #{response.http_status} payload redacted>"
end
