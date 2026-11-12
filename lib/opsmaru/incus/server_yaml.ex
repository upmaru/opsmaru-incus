defmodule Opsmaru.Incus.ServerYaml do
  @moduledoc """
  Byte-exact counterpart of the pinned `ServerFiltered.MarshalYAML` output as
  produced by go-yaml v4 `yaml.Marshal` (v3-compatible defaults: four-space
  indent, unlimited line width).

  Contract: an accepted value renders exactly the native bytes; anything
  outside the supported subset is rejected. Supported strings are single-line
  printable text without tabs; map keys are ASCII with digit runs shorter than
  19 digits (native natural ordering is mirrored exactly). Strings whose plain
  form resolves to another type are double-quoted, YAML 1.1 booleans, base-60
  floats and `<<` are single-quoted, and strings the emitter cannot write plain
  (indicators, leading/trailing spaces, document markers) are single-quoted.
  """
  alias Opsmaru.Incus.NativeYaml

  @indent "    "
  @max_key_bytes 128
  @old_bools ~w(y Y yes Yes YES on On ON n N no No NO off Off OFF)
  @base60 ~r/\A[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+(?:\.[0-9_]*)?\z/

  @top ~w(api_status api_version auth public auth_methods auth_user_name auth_user_method)
  @environment [
    {"addresses", :list},
    {"architectures", :list},
    {"certificate", :string},
    {"certificate_fingerprint", :string},
    {"driver", :string},
    {"driver_version", :string},
    {"firewall", :string},
    {"kernel", :string},
    {"kernel_architecture", :string},
    {"kernel_features", :map},
    {"kernel_version", :string},
    {"lxc_features", :map},
    {"os_name", :string},
    {"os_version", :string},
    {"project", :string},
    {"server", :string},
    {"server_clustered", :bool},
    {"server_event_mode", :string},
    {"server_name", :string},
    {"server_pid", :int},
    {"server_version", :string},
    {"storage", :string},
    {"storage_version", :string},
    {"storage_supported_drivers", :drivers}
  ]
  @top_types %{"public" => :bool, "auth_methods" => :list}

  @doc "Renders filtered server data (a `ServerFiltered` model map) as native YAML."
  def render(%{} = filtered) do
    environment = filtered["environment"] || %{}
    count = filtered["api_extensions_count"] || 0

    with true <- is_map(environment) and is_integer(count),
         {:ok, config} <- field("config", filtered["config"], :map, ""),
         {:ok, top} <-
           fields(Enum.map(@top, &{&1, Map.get(@top_types, &1, :string)}), filtered, ""),
         {:ok, env} <- fields(@environment, environment, @indent) do
      count_line = if count > 0, do: "api_extensions_count: #{count}\n", else: ""
      {:ok, IO.iodata_to_binary([config, count_line, top, "environment:\n", env])}
    else
      _ -> :error
    end
  end

  def render(_filtered), do: :error

  defp fields(specs, data, indent) do
    Enum.reduce_while(specs, {:ok, []}, fn {name, type}, {:ok, acc} ->
      case field(name, data[name], type, indent) do
        {:ok, text} -> {:cont, {:ok, [acc, text]}}
        :error -> {:halt, :error}
      end
    end)
  end

  # Missing or null fields render the Go zero value.
  defp field(name, value, type, indent) do
    with {:ok, rendered} <- value(value, type, indent), do: {:ok, [indent, name, rendered]}
  end

  defp value(nil, :string, indent), do: value("", :string, indent)
  defp value(nil, :bool, indent), do: value(false, :bool, indent)
  defp value(nil, :int, indent), do: value(0, :int, indent)

  defp value(nil, collection, _indent) when collection in [:list, :map, :drivers],
    do: inline_empty(collection)

  defp value(value, :string, _indent) when is_binary(value) do
    with {:ok, text} <- scalar(value), do: {:ok, [": ", text, "\n"]}
  end

  defp value(value, :bool, _indent) when is_boolean(value),
    do: {:ok, [": ", to_string(value), "\n"]}

  defp value(value, :int, _indent)
       when is_integer(value) and value in -0x8000000000000000..0x7FFFFFFFFFFFFFFF,
       do: {:ok, [": ", Integer.to_string(value), "\n"]}

  defp value([], collection, _indent) when collection in [:list, :drivers],
    do: inline_empty(collection)

  defp value(map, :map, _indent) when map == %{}, do: inline_empty(:map)

  defp value(list, :list, indent) when is_list(list) do
    with {:ok, items} <- each(list, &string_item(&1, indent)), do: {:ok, [":\n", items]}
  end

  defp value(map, :map, indent) when is_map(map) do
    with {:ok, keys} <- sorted_keys(map),
         {:ok, entries} <- each(keys, &entry(&1, map[&1], indent)) do
      {:ok, [":\n", entries]}
    end
  end

  defp value(drivers, :drivers, indent) when is_list(drivers) do
    with {:ok, items} <- each(drivers, &driver(&1, indent)), do: {:ok, [":\n", items]}
  end

  defp value(_value, _type, _indent), do: :error

  defp inline_empty(:map), do: {:ok, ": {}\n"}
  defp inline_empty(_list), do: {:ok, ": []\n"}

  defp string_item(item, indent) when is_binary(item) do
    with {:ok, text} <- scalar(item), do: {:ok, [indent, @indent, "- ", text, "\n"]}
  end

  defp string_item(_item, _indent), do: :error

  defp entry(key, value, indent) when is_binary(value) do
    with {:ok, key} <- scalar(key), {:ok, text} <- scalar(value) do
      {:ok, [indent, @indent, key, ": ", text, "\n"]}
    end
  end

  defp entry(_key, _value, _indent), do: :error

  # ServerStorageDriverInfo has no yaml tags: go-yaml lowercases the field names.
  defp driver(%{} = info, indent) do
    with {:ok, name} <- value(info["Name"], :string, ""),
         {:ok, version} <- value(info["Version"], :string, ""),
         {:ok, remote} <- value(info["Remote"], :bool, "") do
      continuation = [indent, @indent, "  "]

      {:ok,
       [
         indent,
         @indent,
         "- name",
         name,
         continuation,
         "version",
         version,
         continuation,
         "remote",
         remote
       ]}
    end
  end

  defp driver(_info, _indent), do: :error

  defp each(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, text} -> {:cont, {:ok, [acc, text]}}
        :error -> {:halt, :error}
      end
    end)
  end

  # ---------------------------------------------------------------------
  # Scalars (representer.go stringv, desolver.go, emitter.go analyzeScalar).
  # ---------------------------------------------------------------------

  defp scalar(text) do
    cond do
      not supported_text?(text) -> :error
      text in @old_bools or text == "<<" or base60?(text) -> {:ok, single(text)}
      true -> resolved(text)
    end
  end

  defp resolved(text) do
    case NativeYaml.plain_kind(text) do
      :str -> {:ok, if(plain_allowed?(text), do: text, else: single(text))}
      :other -> double(text)
      :unknown -> :error
    end
  end

  defp base60?(<<c, _::binary>> = text) when c in ?0..?9 or c in [?+, ?-],
    do: String.contains?(text, ":") and Regex.match?(@base60, text)

  defp base60?(_text), do: false

  defp single(text), do: ["'", String.replace(text, "'", "''"), "'"]

  # Only escape-free values reach double quoting (numbers, booleans, nulls).
  defp double(text) do
    if String.contains?(text, ["\"", "\\"]), do: :error, else: {:ok, ["\"", text, "\""]}
  end

  # Single-line printable text: no tabs, line breaks (incl. NEL, LS, PS) or BOM.
  defp supported_text?(text) do
    String.valid?(text) and
      text |> String.to_charlist() |> Enum.all?(&(&1 in 0x20..0x7E or printable_unicode?(&1)))
  end

  defp printable_unicode?(c),
    do:
      (c in 0xA0..0xD7FF and c not in [0x2028, 0x2029]) or (c in 0xE000..0xFFFD and c != 0xFEFF) or
        c in 0x10000..0x10FFFF

  defp plain_allowed?(""), do: false

  defp plain_allowed?(text) do
    not (String.starts_with?(text, ["---", "..."]) or String.starts_with?(text, " ") or
           String.ends_with?(text, " ") or block_indicator?(text))
  end

  defp block_indicator?(<<c, _::binary>>) when c in ~c"#,[]{}&*!|>'\"%@`", do: true

  defp block_indicator?(<<c, rest::binary>>)
       when c in [??, ?:, ?-] and (rest == "" or binary_part(rest, 0, 1) == " "), do: true

  defp block_indicator?(text),
    do: String.contains?(text, [": ", " #"]) or String.ends_with?(text, ":")

  # ---------------------------------------------------------------------
  # Map key order (representer.go keyList.Less for string keys).
  # ---------------------------------------------------------------------

  defp sorted_keys(map) do
    keys = Map.keys(map)

    if Enum.all?(keys, &sortable_key?/1),
      do: {:ok, Enum.sort(keys, &(not key_less?(&2, &1)))},
      else: :error
  end

  defp sortable_key?(key) do
    is_binary(key) and byte_size(key) <= @max_key_bytes and
      String.match?(key, ~r/\A[\x20-\x7E]*\z/) and
      not String.match?(key, ~r/[0-9]{19}/)
  end

  defp key_less?(a, b) do
    ar = a |> String.to_charlist() |> List.to_tuple()
    br = b |> String.to_charlist() |> List.to_tuple()
    compare(ar, br, 0, false)
  end

  defp compare(ar, br, i, _digits) when i >= tuple_size(ar) or i >= tuple_size(br),
    do: tuple_size(ar) < tuple_size(br)

  defp compare(ar, br, i, digits) do
    x = elem(ar, i)
    y = elem(br, i)

    cond do
      x == y -> compare(ar, br, i + 1, digit?(x))
      letter?(x) and letter?(y) -> x < y
      letter?(x) or letter?(y) -> if digits, do: letter?(x), else: letter?(y)
      true -> numeric_less?(ar, br, i, x, y)
    end
  end

  # A zero after a non-zero digit run prefix counts as significant (native
  # seeds both accumulators with 1 in that case).
  defp numeric_less?(ar, br, i, x, y) do
    seed = if (x == ?0 or y == ?0) and nonzero_digit_before?(ar, i - 1), do: 1, else: 0
    {an, ai} = accumulate(ar, i, seed)
    {bn, bi} = accumulate(br, i, seed)

    cond do
      an != bn -> an < bn
      ai != bi -> ai < bi
      true -> x < y
    end
  end

  defp nonzero_digit_before?(_ar, j) when j < 0, do: false

  defp nonzero_digit_before?(ar, j) do
    c = elem(ar, j)

    cond do
      not digit?(c) -> false
      c != ?0 -> true
      true -> nonzero_digit_before?(ar, j - 1)
    end
  end

  defp accumulate(chars, i, value) when i < tuple_size(chars) do
    c = elem(chars, i)
    if digit?(c), do: accumulate(chars, i + 1, value * 10 + c - ?0), else: {value, i}
  end

  defp accumulate(_chars, i, value), do: {value, i}

  defp digit?(c), do: c in ?0..?9
  defp letter?(c), do: c in ?a..?z or c in ?A..?Z
end
