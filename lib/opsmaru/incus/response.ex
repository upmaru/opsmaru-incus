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
