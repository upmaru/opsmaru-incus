defmodule Opsmaru.Incus.Constants do
  @moduledoc """
  Pinned native API constant values, addressed by their original string names.

  These are model data, not capability grants or service configuration. Returning
  an authentication or lifecycle enum does not implement its protocol or enable
  a feature. Lookups perform no I/O, create no atoms and start no application.
  """
  alias Opsmaru.Incus.Error
  @external_resource Path.expand("../../../priv/incus/constants.json", __DIR__)
  @values Jason.decode!(File.read!(@external_resource))["values"]

  def names, do: @values |> Map.keys() |> Enum.sort()

  def fetch(name) when is_binary(name) and byte_size(name) <= 256 do
    case Map.fetch(@values, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %Error{kind: :unknown_native_constant}}
    end
  end

  def fetch(_), do: {:error, %Error{kind: :invalid_arguments}}
end
