defmodule Opsmaru.Incus.Operations.Schema do
  @moduledoc """
  Validates operation input against its own JSON Schema subset.

  Descriptor schemas are the only definition of an operation's input; direct
  callers and the MCP binding both validate against them. Only the keywords in
  `keywords/0` are supported, so a schema cannot claim a constraint this
  validator ignores. Lengths count characters as JSON Schema does; byte bounds
  are enforced separately by each descriptor.
  """

  @keywords ~w(type title description properties required additionalProperties
               minLength maxLength pattern enum minimum maximum items minItems
               maxItems maxProperties propertyNames oneOf default)

  @doc "JSON Schema keywords this validator implements."
  def keywords, do: @keywords

  @doc "Validate `value`; returns `:ok` or `{:error, path, reason}` with a JSON-pointer-like path."
  def validate(schema, value), do: check(schema, value, "")

  defp check(schema, value, path) do
    with :ok <- type(schema, value, path),
         :ok <- enum(schema, value, path),
         :ok <- string(schema, value, path),
         :ok <- number(schema, value, path),
         :ok <- array(schema, value, path),
         :ok <- object(schema, value, path) do
      one_of(schema, value, path)
    end
  end

  defp type(%{"type" => type}, value, path) do
    if Enum.any?(List.wrap(type), &type?(&1, value)),
      do: :ok,
      else: {:error, path, "must be #{Enum.join(List.wrap(type), " or ")}"}
  end

  defp type(_, _, _), do: :ok

  defp type?("object", value), do: is_map(value)
  defp type?("array", value), do: is_list(value)
  defp type?("string", value), do: is_binary(value) and String.valid?(value)
  defp type?("integer", value), do: is_integer(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("null", value), do: is_nil(value)

  defp enum(%{"enum" => values}, value, path),
    do: if(value in values, do: :ok, else: {:error, path, "is not an allowed value"})

  defp enum(_, _, _), do: :ok

  defp string(schema, value, path) when is_binary(value) do
    length = String.length(value)

    cond do
      length < Map.get(schema, "minLength", 0) -> {:error, path, "is too short"}
      length > Map.get(schema, "maxLength", length) -> {:error, path, "is too long"}
      not pattern?(schema, value) -> {:error, path, "does not match its pattern"}
      true -> :ok
    end
  end

  defp string(_, _, _), do: :ok

  defp pattern?(%{"pattern" => pattern}, value),
    do: Regex.match?(Regex.compile!(pattern, "u"), value)

  defp pattern?(_, _), do: true

  defp number(schema, value, path) when is_integer(value) do
    cond do
      value < Map.get(schema, "minimum", value) -> {:error, path, "is below its minimum"}
      value > Map.get(schema, "maximum", value) -> {:error, path, "is above its maximum"}
      true -> :ok
    end
  end

  defp number(_, _, _), do: :ok

  defp array(schema, value, path) when is_list(value) do
    count = length(value)

    cond do
      count < Map.get(schema, "minItems", 0) ->
        {:error, path, "has too few items"}

      count > Map.get(schema, "maxItems", count) ->
        {:error, path, "has too many items"}

      items = schema["items"] ->
        value
        |> Enum.with_index()
        |> first_error(fn {item, index} -> check(items, item, "#{path}/#{index}") end)

      true ->
        :ok
    end
  end

  defp array(_, _, _), do: :ok

  defp object(schema, value, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    cond do
      map_size(value) > Map.get(schema, "maxProperties", map_size(value)) ->
        {:error, path, "has too many properties"}

      missing = Enum.find(Map.get(schema, "required", []), &(not Map.has_key?(value, &1))) ->
        {:error, "#{path}/#{missing}", "is required"}

      true ->
        first_error(value, fn {key, item} ->
          property(schema, properties, key, item, "#{path}/#{key}")
        end)
    end
  end

  defp object(_, _, _), do: :ok

  defp property(schema, properties, key, item, path) do
    with :ok <- property_name(schema, key, path) do
      case {Map.fetch(properties, key), Map.get(schema, "additionalProperties", true)} do
        {{:ok, property}, _} -> check(property, item, path)
        {:error, false} -> {:error, path, "is not allowed"}
        {:error, true} -> :ok
        {:error, additional} -> check(additional, item, path)
      end
    end
  end

  defp property_name(%{"propertyNames" => names}, key, path) do
    case check(names, key, path) do
      :ok -> :ok
      {:error, _, reason} -> {:error, path, "property name #{reason}"}
    end
  end

  defp property_name(_, _, _), do: :ok

  defp one_of(%{"oneOf" => schemas}, value, path) do
    case Enum.count(schemas, &(check(&1, value, path) == :ok)) do
      1 -> :ok
      _ -> {:error, path, "must match exactly one schema"}
    end
  end

  defp one_of(_, _, _), do: :ok

  defp first_error(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
