defmodule Opsmaru.Incus.Response do
  @moduledoc "Native Incus envelope with lossless metadata/unknown fields and ETag."
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
end

defimpl Inspect, for: Opsmaru.Incus.Response do
  def inspect(response, _),
    do: "#Opsmaru.Incus.Response<#{response.type} HTTP #{response.http_status} payload redacted>"
end
