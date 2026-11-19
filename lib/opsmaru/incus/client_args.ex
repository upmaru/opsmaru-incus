defmodule Opsmaru.Incus.ClientArgs do
  @moduledoc """
  The pinned client's argument structs mapped to the options of the Elixir
  functions that take their place. Pure data: nothing here performs I/O.

  `fields/1` lists every field of a pinned struct, in declaration order with
  promoted fields of an embedded struct expanded in place, with its Go type and
  its mapping: `{:option, key}` when the Elixir function takes the field as the
  keyword option `key`, or `{:ignored, reason}` when the pinned method never
  reads it. `options/2` turns a struct value written as a map keyed by Go field
  name into those options.

  Go cannot tell an unset field from its zero value, so `options/2` drops
  `false`, `""` and `nil` and keeps lists, including an empty one (a non-nil
  empty `Profiles` clears the target's profiles in the pinned `CopyImage`).
  Approved differences: a `Mode` other than `"pull"`, `"push"` or `"relay"`,
  which the pinned methods treat as a pull, is rejected; unknown or misspelled
  field names, which Go's JSON decoding would ignore or case-fold, are
  rejected; and options that are host decisions rather than struct fields
  (`approved_origin`, `relay`, `registry_credentials`) never come from a struct.
  """
  alias Opsmaru.Incus.Error

  @modes ~w(pull push relay)
  @move_ignored "the pinned MoveStoragePoolVolume sends only Name, Pool and Project"

  @args %{
    "ImageCopyArgs" => %{
      function: {Opsmaru.Incus.Images, :copy, 4},
      mode: :string,
      fields: [
        {"Aliases", "[]api.ImageAlias", {:option, :aliases}},
        {"AutoUpdate", "bool", {:option, :auto_update}},
        {"CopyAliases", "bool", {:option, :copy_aliases}},
        {"Public", "bool", {:option, :public}},
        {"Type", "string", {:option, :type}},
        {"Mode", "string", {:option, :mode}},
        {"Profiles", "[]string", {:option, :profiles}}
      ]
    },
    "InstanceCopyArgs" => %{
      function: {Opsmaru.Incus.Copy, :instance, 4},
      mode: :atom,
      fields: [
        {"Name", "string", {:option, :name}},
        {"Live", "bool", {:option, :live}},
        {"InstanceOnly", "bool", {:option, :instance_only}},
        {"Mode", "string", {:option, :mode}},
        {"Refresh", "bool", {:option, :refresh}},
        {"RefreshExcludeOlder", "bool", {:option, :refresh_exclude_older}},
        {"AllowInconsistent", "bool", {:option, :allow_inconsistent}}
      ]
    },
    "InstanceSnapshotCopyArgs" => %{
      function: {Opsmaru.Incus.Copy, :snapshot, 5},
      mode: :atom,
      fields: [
        {"Name", "string", {:option, :name}},
        {"Mode", "string", {:option, :mode}},
        {"Live", "bool", {:option, :live}}
      ]
    },
    "StoragePoolVolumeCopyArgs" => %{
      function: {Opsmaru.Incus.Copy, :volume, 6},
      mode: :atom,
      fields: [
        {"Name", "string", {:option, :name}},
        {"Mode", "string", {:option, :mode}},
        {"VolumeOnly", "bool", {:option, :volume_only}},
        {"Refresh", "bool", {:option, :refresh}},
        {"RefreshExcludeOlder", "bool", {:option, :refresh_exclude_older}}
      ]
    },
    "StoragePoolVolumeMoveArgs" => %{
      function: {Opsmaru.Incus.Copy, :move_volume, 5},
      mode: :atom,
      embedded: ["StoragePoolVolumeCopyArgs"],
      fields: [
        {"Name", "string", {:option, :name}},
        {"Mode", "string", {:ignored, @move_ignored}},
        {"VolumeOnly", "bool", {:ignored, @move_ignored}},
        {"Refresh", "bool", {:ignored, @move_ignored}},
        {"RefreshExcludeOlder", "bool", {:ignored, @move_ignored}},
        {"Project", "string", {:option, :project}}
      ]
    }
  }

  @doc "The mapped pinned struct names, sorted."
  def types, do: @args |> Map.keys() |> Enum.sort()

  @doc "The Elixir function `{module, name, arity}` that takes the struct's options."
  def function(type) when is_map_key(@args, type), do: @args[type].function

  @doc "The structs embedded in `type`, whose fields `fields/1` lists in place."
  def embedded(type) when is_map_key(@args, type), do: Map.get(@args[type], :embedded, [])

  @doc "Every field of `type` as `{go_name, go_type, mapping}`, in declaration order."
  def fields(type) when is_map_key(@args, type), do: @args[type].fields

  @doc """
  Options for `function/1` from a struct value given as a map keyed by Go field
  name (strings or atoms). Returns `{:ok, keyword}` in field order, or
  `{:error, %Error{kind: :invalid_client_args}}` for an unknown struct, an
  unknown field, a value of the wrong type or an unsupported `Mode`.
  """
  def options(type, native) when is_map_key(@args, type) and is_map(native) do
    spec = @args[type]
    known = Enum.map(spec.fields, &elem(&1, 0))

    with {:ok, given} <- named(native),
         [] <- Map.keys(given) -- known,
         {:ok, options} <- collect(spec, given) do
      {:ok, options}
    else
      _ -> invalid()
    end
  end

  def options(_type, _native), do: invalid()

  defp collect(spec, given) do
    Enum.reduce_while(spec.fields, {:ok, []}, fn {name, go_type, mapping}, {:ok, acc} ->
      value = Map.get(given, name)

      case convert(go_type, name, value, spec.mode) do
        :error -> {:halt, :error}
        :skip -> {:cont, {:ok, acc}}
        {:ok, _} when elem(mapping, 0) == :ignored -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, acc ++ [{elem(mapping, 1), value}]}}
      end
    end)
  end

  defp convert(_, _, nil, _), do: :skip
  defp convert("bool", _, false, _), do: :skip
  defp convert("bool", _, true, _), do: {:ok, true}
  defp convert("string", _, "", _), do: :skip
  defp convert("string", "Mode", mode, :string) when mode in @modes, do: {:ok, mode}
  defp convert("string", "Mode", mode, :atom) when mode in @modes, do: {:ok, mode_atom(mode)}
  defp convert("string", "Mode", _, _), do: :error
  defp convert("string", _, value, _) when is_binary(value), do: {:ok, value}

  defp convert("[]string", _, values, _) when is_list(values),
    do: if(Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error)

  defp convert("[]api.ImageAlias", _, values, _) when is_list(values) do
    if Enum.all?(values, &alias?/1),
      do: {:ok, Enum.map(values, &alias_map/1)},
      else: :error
  end

  defp convert(_, _, _, _), do: :error

  defp mode_atom("pull"), do: :pull
  defp mode_atom("push"), do: :push
  defp mode_atom("relay"), do: :relay

  # api.ImageAlias: name and description, keyed as the native JSON names them.
  defp alias?(value) when is_map(value) do
    case named(value) do
      {:ok, entry} ->
        Map.keys(entry) -- ["name", "description"] == [] and
          Enum.all?(Map.values(entry), &is_binary/1)

      :error ->
        false
    end
  end

  defp alias?(_), do: false

  defp alias_map(value) do
    {:ok, entry} = named(value)
    entry
  end

  # A map keyed by strings or atoms, rekeyed by string; any other key, or two
  # keys naming the same field, is an error.
  defp named(map) do
    if Enum.all?(Map.keys(map), &(is_binary(&1) or is_atom(&1))) do
      given = Map.new(map, fn {key, value} -> {to_string(key), value} end)
      if map_size(given) == map_size(map), do: {:ok, given}, else: :error
    else
      :error
    end
  end

  defp invalid, do: {:error, %Error{kind: :invalid_client_args}}
end
