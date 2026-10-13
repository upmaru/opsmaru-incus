defmodule Opsmaru.Incus.PreseedConfig do
  @moduledoc false
  alias Opsmaru.Incus.{Error, Model, NativeInput}

  @collections ~w(networks storage_pools storage_volumes profiles projects certificates cluster_groups)

  def prepare(value, limit) do
    with data when is_map(data) <- Model.encode(value),
         {:ok, json} <- Jason.encode(data),
         true <- byte_size(json) <= limit,
         {:ok, data} <- NativeInput.cast("InitPreseed", data),
         true <- Enum.sum(Enum.map(@collections, &length(data[&1] || []))) <= 128,
         true <- bounded_identifiers?(data),
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
    NativeInput.cast(type, value)
  end

  defp bounded_identifiers?(data),
    do:
      Enum.all?(@collections, fn collection ->
        Enum.all?(data[collection] || [], fn item ->
          Enum.all?(~w(name Project Pool type), fn key ->
            not Map.has_key?(item, key) or byte_size(item[key]) <= 1024
          end)
        end)
      end)
end
