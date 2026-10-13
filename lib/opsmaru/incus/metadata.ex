defmodule Opsmaru.Incus.Metadata do
  @moduledoc "Pure bounded native configuration-key lookup; does not apply configuration or contact Incus."
  alias Opsmaru.Incus.{Error, Model, Response}

  def keys(model, entity, group)

  def keys(%Model{type: "MetadataConfiguration", data: data}, entity, group),
    do: keys(data, entity, group)

  def keys(%Model{}, _, _), do: invalid()

  def keys(data, entity, group) when is_map(data) or is_nil(data) do
    with true <- valid_name?(entity) and valid_name?(group),
         {:ok, model} <-
           Response.metadata_as_model(%Response{metadata: data}, "MetadataConfiguration"),
         {:ok, groups} <- lookup(model.data["configs"] || %{}, entity, "entity"),
         {:ok, config} <- lookup(groups || %{}, group, "group") do
      {:ok,
       Enum.reduce(config["keys"] || [], %{}, fn item, acc -> Map.merge(acc, item || %{}) end)}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> invalid()
    end
  end

  def keys(_, _, _), do: invalid()

  defp lookup(map, name, kind) do
    case Map.fetch(map, name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         %Error{
           kind: :native_metadata,
           message: "Requested configuration #{kind} #{quote_name(name)} doesn't exist"
         }}
    end
  end

  defp valid_name?(name), do: is_binary(name) and byte_size(name) <= 1024 and String.valid?(name)
  defp invalid, do: {:error, %Error{kind: :invalid_metadata}}

  # Go %q uses printable Unicode categories and C escapes. Preserve its native
  # diagnostic string without writing it to logs or allocating runtime atoms.
  defp quote_name(name),
    do: "\"" <> Enum.map_join(String.to_charlist(name), &quote_char/1) <> "\""

  defp quote_char(char) do
    case char do
      7 -> "\\a"
      8 -> "\\b"
      9 -> "\\t"
      10 -> "\\n"
      11 -> "\\v"
      12 -> "\\f"
      13 -> "\\r"
      34 -> "\\\""
      92 -> "\\\\"
      32 -> " "
      _ -> quote_unicode(char)
    end
  end

  defp quote_unicode(char) do
    value = <<char::utf8>>

    if Regex.match?(~r/\A[\p{L}\p{M}\p{N}\p{P}\p{S}]\z/u, value) do
      value
    else
      {prefix, width} =
        cond do
          char < 128 -> {"\\x", 2}
          char <= 0xFFFF -> {"\\u", 4}
          true -> {"\\U", 8}
        end

      prefix <> String.pad_leading(Integer.to_string(char, 16) |> String.downcase(), width, "0")
    end
  end
end
