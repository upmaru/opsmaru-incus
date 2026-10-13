defmodule Opsmaru.Incus.NativeYaml do
  @moduledoc """
  Strict-subset YAML decoding for native ConfigMap/DevicesMap values.

  Contract: every accepted document decodes to exactly what the pinned
  go-yaml v4 `UnmarshalYAML` produces; everything else is rejected. Input
  outside the subset is rejected even when the native decoder would accept it.

  Supported: one document holding a block or flow mapping (ConfigMap values
  are scalars; DevicesMap values are mappings of scalars), string keys,
  quoted/block scalars as strings, plain scalars resolved with go-yaml v4
  rules, anchors on scalars and block mappings, aliases, and `<<` merge keys
  (alias, mapping or sequence of those) with native precedence.

  Rejected: explicit tags, directives, additional documents, sequences other
  than merge lists, nesting deeper than four collections, anchors inside flow
  collections or on keys, non-string plain keys, date-like plain scalars, more
  than 100 alias expansions and numeric forms outside the mirrored resolver.
  yamerl stops at the first rejected token, so pathological input is cheap.
  """
  alias Opsmaru.Incus.NativeConfig

  @max_depth 4
  @max_tokens 400_000
  @max_aliases 100
  @max_work 1_000_000
  @max_numeric_bytes 400
  @max_reductions 100_000_000
  @max_heap_words 64 * 1024 * 1024
  @max_millis 2_000
  @poll_millis 20
  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807
  @uint64_max 18_446_744_073_709_551_615

  # go-yaml v4 resolver table entries (resolver.go resolveMap).
  @resolve_map %{
                 "true" => {:bool, true},
                 "True" => {:bool, true},
                 "TRUE" => {:bool, true},
                 "false" => {:bool, false},
                 "False" => {:bool, false},
                 "FALSE" => {:bool, false},
                 "" => :null,
                 "~" => :null,
                 "null" => :null,
                 "Null" => :null,
                 "NULL" => :null,
                 "-0" => :neg_zero,
                 "-0.0" => :neg_zero,
                 "<<" => :merge
               }
               |> Map.merge(Map.new(~w(.nan .NaN .NAN), &{&1, :nan}))
               |> Map.merge(Map.new(~w(.inf .Inf .INF +.inf +.Inf +.INF), &{&1, :pos_inf}))
               |> Map.merge(Map.new(~w(-.inf -.Inf -.INF), &{&1, :neg_inf}))

  @yaml_float ~r/\A(?<sign>[-+]?)(?:\.(?<dot>[0-9]+)|(?<int>[0-9]+)(?:\.(?<frac>[0-9]*))?)(?:[eE](?<exp>[-+]?[0-9]+))?\z/
  @dot_float ~r/\A\.[0-9]+(?:[eE][-+]?[0-9]+)?\z/

  @doc """
  Decodes `yaml` for `:config_map` or `:devices_map` merged into `existing`.
  Returns `{:ok, map | nil}` or `:error`; never raises.
  """
  def decode(type, yaml, existing) when type in [:config_map, :devices_map] do
    if String.valid?(yaml) and :binary.match(yaml, <<0>>) == :nomatch,
      do: bounded(fn -> decode_tokens(type, yaml, existing) end),
      else: :error
  end

  defp decode_tokens(type, yaml, existing) do
    with {:ok, tokens} <- tokenize(yaml), do: document(type, tokens, existing)
  end

  # yamerl buffers flow collections that could still become implicit keys and
  # rescans them quadratically, before any token reaches the gate. Decoding
  # therefore runs in a linked worker with a CPU (reduction) budget and heap
  # cap; exceeding either rejects the document. The worker dies with the caller.
  defp bounded(fun) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(fn -> send(caller, {ref, contain(fun)}) end, [
        :link,
        :monitor,
        max_heap_size: %{size: @max_heap_words, kill: true, error_logger: false}
      ])

    {result, down?} = await(pid, monitor, ref, System.monotonic_time(:millisecond) + @max_millis)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    # Wait for termination so no result can arrive after we return.
    unless down? do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      end
    end

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end

    receive do
      {^ref, _late} -> :ok
    after
      0 -> :ok
    end

    result
  end

  # A crash in the worker becomes a rejection instead of an exit signal that
  # would terminate a caller that does not trap exits.
  defp contain(fun) do
    fun.()
  catch
    _kind, _reason -> :error
  end

  defp await(pid, monitor, ref, deadline) do
    receive do
      {^ref, result} ->
        {result, false}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        receive do
          {^ref, result} -> {result, true}
        after
          0 -> {:error, true}
        end
    after
      @poll_millis ->
        with {:reductions, reductions} when reductions <= @max_reductions <-
               Process.info(pid, :reductions),
             true <- System.monotonic_time(:millisecond) < deadline do
          await(pid, monitor, ref, deadline)
        else
          _ -> {:error, false}
        end
    end
  end

  # ---------------------------------------------------------------------
  # Tokens. The gate runs inside yamerl's token callback and throws on the
  # first token outside the subset, which stops scanning immediately.
  # ---------------------------------------------------------------------

  defp tokenize(yaml) do
    gate = gate(%{depth: 0, flow: 0, docs: 0, count: 0, prev: nil, acc: []})

    with {:ok, parser} <- scan(yaml, gate) do
      {:collected, tokens} = :yamerl_parser.get_token_fun(parser).({__MODULE__, :collect})
      {:ok, tokens}
    end
  end

  # Only the third-party scanner call is guarded: besides its structured
  # parse errors, yamerl crashes on some malformed input (e.g. ": :").
  defp scan(yaml, gate) do
    {:ok, :yamerl_parser.string(yaml, [{:token_fun, gate}])}
  catch
    :throw, {__MODULE__, :reject} -> :error
    :throw, {:yamerl_exception, _errors} -> :error
    :error, _yamerl_fault -> :error
  end

  defp gate(state) do
    fn
      {__MODULE__, :collect} ->
        {:collected, Enum.reverse(state.acc)}

      token ->
        case admit(token, state) do
          {:ok, state} ->
            {:ok, gate(%{state | prev: elem(token, 0), acc: [token | state.acc]})}

          :reject ->
            throw({__MODULE__, :reject})
        end
    end
  end

  defp admit(_token, %{count: count}) when count >= @max_tokens, do: :reject

  defp admit(token, state), do: allow(token, %{state | count: state.count + 1})

  defp allow({:yamerl_doc_start, _, _, _, _}, %{docs: 0} = state), do: {:ok, %{state | docs: 1}}

  defp allow({:yamerl_collection_start, _, _, tag, style, _}, state)
       when state.depth < @max_depth and elem(tag, 3) == {:non_specific, ~c"?"},
       do: {:ok, %{state | depth: state.depth + 1, flow: state.flow + flow(style)}}

  defp allow({:yamerl_collection_end, _, _, style, _}, state),
    do: {:ok, %{state | depth: state.depth - 1, flow: state.flow - flow(style)}}

  # yamerl reorders an anchor on a flow collection after the first key,
  # which makes it indistinguishable from an anchored key: reject both.
  defp allow({:yamerl_anchor, _, _, _}, state)
       when state.flow == 0 and state.prev != :yamerl_mapping_key,
       do: {:ok, state}

  # Untagged scalars only: plain ones carry "?", quoted/block ones "!".
  defp allow({:yamerl_scalar, _, _, tag, _, substyle, _}, state) do
    case {elem(tag, 3), substyle} do
      {{:non_specific, ~c"?"}, :plain} -> {:ok, state}
      {{:non_specific, ~c"!"}, substyle} when substyle != :plain -> {:ok, state}
      _ -> :reject
    end
  end

  defp allow({kind, _, _}, state)
       when kind in [
              :yamerl_stream_end,
              :yamerl_doc_end,
              :yamerl_mapping_key,
              :yamerl_mapping_value,
              :yamerl_sequence_entry
            ],
       do: {:ok, state}

  defp allow({kind, _, _, _}, state) when kind in [:yamerl_stream_start, :yamerl_alias],
    do: {:ok, state}

  defp allow(_token, _state), do: :reject

  defp flow(:flow), do: 1
  defp flow(:block), do: 0

  # ---------------------------------------------------------------------
  # Document and node structure.
  # Nodes: {:scalar, term} | {:map, [{key, node}], merge_node | nil} |
  # {:seq, [node]} | {:alias, node}.
  # ---------------------------------------------------------------------

  defp document(_type, [{:yamerl_stream_start, _, _, _}, {:yamerl_stream_end, _, _}], existing),
    do: {:ok, existing}

  defp document(
         type,
         [{:yamerl_stream_start, _, _, _}, {:yamerl_doc_start, _, _, _, _} | rest],
         existing
       ) do
    with {:ok, root, rest, _ctx} <- root(rest, %{anchors: %{}, open: MapSet.new()}),
         [{:yamerl_doc_end, _, _}, {:yamerl_stream_end, _, _}] <- rest do
      result(type, root, existing)
    else
      _ -> :error
    end
  end

  defp document(_type, _tokens, _existing), do: :error

  # "---" with no content is a null document.
  defp root([{:yamerl_doc_end, _, _} | _] = rest, ctx), do: {:ok, {:scalar, :null}, rest, ctx}
  defp root(tokens, ctx), do: node(tokens, ctx)

  # A null document resets the target natively; any other non-mapping root
  # cannot decode into a map.
  defp result(_type, {:scalar, :null}, _existing), do: {:ok, nil}

  defp result(type, {:map, _, _} = root, existing) do
    with {:ok, value, _budget} <- fold(root, value_kind(type), budget()) do
      {:ok, merge_existing(type, value, existing || %{})}
    end
  end

  defp result(_type, _root, _existing), do: :error

  defp value_kind(:config_map), do: :scalar
  defp value_kind(:devices_map), do: :device

  defp merge_existing(:config_map, value, existing), do: Map.merge(existing, value)

  defp merge_existing(:devices_map, value, existing) do
    Enum.reduce(value, existing, fn {name, props}, acc ->
      Map.put(acc, name, Map.merge(Map.get(acc, name, %{}), props))
    end)
  end

  defp node([{:yamerl_anchor, _, _, name} | rest], ctx) do
    name = List.to_string(name)

    with true <- anchorable?(rest),
         {:ok, node, rest, ctx} <- node(rest, %{ctx | open: MapSet.put(ctx.open, name)}) do
      anchors = Map.put(ctx.anchors, name, node)
      {:ok, node, rest, %{ctx | anchors: anchors, open: MapSet.delete(ctx.open, name)}}
    else
      _ -> :error
    end
  end

  # Undefined, forward and self-referencing aliases are native errors.
  defp node([{:yamerl_alias, _, _, name} | rest], ctx) do
    name = List.to_string(name)

    with false <- MapSet.member?(ctx.open, name),
         {:ok, node} <- Map.fetch(ctx.anchors, name) do
      {:ok, {:alias, node}, rest, ctx}
    else
      _ -> :error
    end
  end

  defp node([{:yamerl_scalar, _, _, _, _, substyle, text} | rest], ctx) do
    case scalar(substyle, List.to_string(text)) do
      :reject -> :error
      term -> {:ok, {:scalar, term}, rest, ctx}
    end
  end

  defp node([{:yamerl_collection_start, _, _, _, _, :mapping} | rest], ctx),
    do: mapping(rest, ctx, [], nil, MapSet.new())

  defp node([{:yamerl_collection_start, _, _, _, _, :sequence} | rest], ctx),
    do: sequence(rest, ctx, [])

  defp node(_tokens, _ctx), do: :error

  defp anchorable?([{:yamerl_scalar, _, _, _, _, _, _} | _]), do: true
  defp anchorable?([{:yamerl_collection_start, _, _, _, :block, :mapping} | _]), do: true
  defp anchorable?(_tokens), do: false

  # Keys are compared by their scalar text for duplicates, as native does
  # (merge keys included); explicit keys follow input order.
  defp mapping([{:yamerl_collection_end, _, _, _, :mapping} | rest], ctx, entries, merge, _seen),
    do: {:ok, {:map, Enum.reverse(entries), merge}, rest, ctx}

  defp mapping(
         [{:yamerl_mapping_key, _, _}, {:yamerl_scalar, _, _, _, _, substyle, text} | rest],
         ctx,
         entries,
         merge,
         seen
       ) do
    raw = List.to_string(text)

    with false <- MapSet.member?(seen, raw),
         {:ok, key} <- key(substyle, raw),
         {:ok, value, rest, ctx} <- value(rest, ctx) do
      seen = MapSet.put(seen, raw)

      cond do
        key != :merge -> mapping(rest, ctx, [{key, value} | entries], merge, seen)
        merge_source?(value) -> mapping(rest, ctx, entries, value, seen)
        true -> :error
      end
    else
      _ -> :error
    end
  end

  defp mapping(_tokens, _ctx, _entries, _merge, _seen), do: :error

  defp value([{:yamerl_mapping_value, _, _} | rest], ctx), do: node(rest, ctx)
  defp value(rest, ctx), do: {:ok, {:scalar, :null}, rest, ctx}

  defp sequence([{:yamerl_collection_end, _, _, _, :sequence} | rest], ctx, items),
    do: {:ok, {:seq, Enum.reverse(items)}, rest, ctx}

  defp sequence([{:yamerl_sequence_entry, _, _} | rest], ctx, items) do
    with {:ok, item, rest, ctx} <- node(rest, ctx), do: sequence(rest, ctx, [item | items])
  end

  defp sequence(_tokens, _ctx, _items), do: :error

  defp key(:plain, raw) do
    case plain(raw) do
      {:str, key} -> {:ok, key}
      :merge -> {:ok, :merge}
      _ -> :error
    end
  end

  defp key(_substyle, raw), do: {:ok, raw}

  # Native merge values: a mapping, an alias to one, or a sequence of those.
  defp merge_source?({:seq, items}), do: items != [] and Enum.all?(items, &merge_map?/1)
  defp merge_source?(node), do: merge_map?(node)

  defp merge_map?({:map, _, _}), do: true
  defp merge_map?({:alias, {:map, _, _}}), do: true
  defp merge_map?(_node), do: false

  # ---------------------------------------------------------------------
  # Construction. Explicit keys win, then earlier merge sources win over
  # later ones (constructor.go mapping/merge). Alias expansions and folded
  # entries are budgeted; native rejects aliasing only above 100 aliases.
  # ---------------------------------------------------------------------

  defp budget, do: %{aliases: 0, work: 0}

  defp fold({:alias, node}, kind, budget) do
    with {:ok, budget} <- expand(budget), do: fold(node, kind, budget)
  end

  defp fold({:map, entries, merge}, kind, budget) do
    with {:ok, explicit, budget} <- fold_entries(entries, kind, budget, %{}),
         {:ok, merged, budget} <- fold_merge(merge, kind, budget) do
      work = budget.work + map_size(explicit) + map_size(merged)

      if work > @max_work,
        do: :error,
        else: {:ok, Map.merge(merged, explicit), %{budget | work: work}}
    end
  end

  defp fold(_node, _kind, _budget), do: :error

  defp expand(%{aliases: aliases} = budget) when aliases < @max_aliases,
    do: {:ok, %{budget | aliases: aliases + 1}}

  defp expand(_budget), do: :error

  defp fold_entries([], _kind, budget, acc), do: {:ok, acc, budget}

  defp fold_entries([{key, node} | rest], kind, budget, acc) do
    with {:ok, value, budget} <- fold_value(node, kind, budget),
         do: fold_entries(rest, kind, budget, Map.put(acc, key, value))
  end

  defp fold_value({:alias, node}, kind, budget) do
    with {:ok, budget} <- expand(budget), do: fold_value(node, kind, budget)
  end

  defp fold_value({:scalar, term}, :scalar, budget) do
    with {:ok, string} <- native_string(term), do: {:ok, string, budget}
  end

  defp fold_value({:map, _, _} = node, :device, budget), do: fold(node, :scalar, budget)
  defp fold_value(_node, _kind, _budget), do: :error

  defp fold_merge(nil, _kind, budget), do: {:ok, %{}, budget}

  defp fold_merge({:seq, sources}, kind, budget) do
    Enum.reduce_while(sources, {:ok, %{}, budget}, fn source, {:ok, acc, budget} ->
      case fold(source, kind, budget) do
        {:ok, folded, budget} -> {:cont, {:ok, Map.merge(folded, acc), budget}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp fold_merge(source, kind, budget), do: fold(source, kind, budget)

  # ConfigMap/DevicesMap stringification (config.go fromMapStringAny).
  defp native_string(:null), do: {:ok, ""}
  defp native_string({:bool, bool}), do: {:ok, Atom.to_string(bool)}
  defp native_string({:int, int}), do: {:ok, Integer.to_string(int)}
  defp native_string({:float, float}), do: NativeConfig.native_string(float)
  defp native_string(:neg_zero), do: {:ok, "0"}
  defp native_string(:nan), do: {:ok, "NaN"}
  defp native_string(:pos_inf), do: {:ok, "+Inf"}
  defp native_string(:neg_inf), do: {:ok, "-Inf"}
  defp native_string({:str, string}), do: {:ok, string}
  defp native_string(_term), do: :error

  # ---------------------------------------------------------------------
  # Scalar resolution (go-yaml v4 resolver.go). Quoted and block scalars are
  # strings; plain scalars follow the resolver's first-byte hint table.
  # ---------------------------------------------------------------------

  defp scalar(:plain, text), do: plain(text)
  defp scalar(_substyle, text), do: {:str, text}

  defp plain(text) do
    case Map.fetch(@resolve_map, text) do
      {:ok, term} -> term
      :error -> hinted(text)
    end
  end

  # Reserved indicators cannot start a plain scalar in libyaml; yamerl allows them.
  defp hinted(<<c, _::binary>>) when c in [?@, ?`], do: :reject
  defp hinted(<<c, _::binary>> = text) when c in ?0..?9 or c in [?+, ?-], do: numeric(text)
  defp hinted(<<?., _::binary>> = text), do: dot(text)
  defp hinted(text), do: {:str, text}

  # Digit/sign hint: timestamp, then base-0 int64, then uint64, then the
  # YAML float pattern, all after removing underscores. Date-like and very
  # long numeric scalars are outside the subset.
  defp numeric(text) when byte_size(text) > @max_numeric_bytes, do: :reject

  defp numeric(text) do
    plain = String.replace(text, "_", "")

    cond do
      String.match?(text, ~r/\A[0-9]{4}-/) -> :reject
      (int = base0(plain, true)) != :error and int in @int64_min..@int64_max -> {:int, int}
      (uint = base0(plain, false)) != :error and uint in 0..@uint64_max -> {:int, uint}
      Regex.match?(@yaml_float, plain) -> float(plain)
      true -> {:str, text}
    end
  end

  # strconv base-0 syntax: optional sign (signed only), then 0x/0o/0b
  # prefixes, a leading 0 for octal, or decimal digits.
  defp base0(<<sign, rest::binary>>, true) when sign in [?+, ?-] do
    case unsigned(rest) do
      :error -> :error
      value when sign == ?- -> -value
      value -> value
    end
  end

  defp base0(text, _signed), do: unsigned(text)

  defp unsigned(<<?0, p, digits::binary>>) when p in [?x, ?X], do: digits(digits, 16)
  defp unsigned(<<?0, p, digits::binary>>) when p in [?o, ?O], do: digits(digits, 8)
  defp unsigned(<<?0, p, digits::binary>>) when p in [?b, ?B], do: digits(digits, 2)
  defp unsigned(<<?0, digits::binary>>) when digits != "", do: digits(digits, 8)
  defp unsigned(digits), do: digits(digits, 10)

  defp digits(digits, base) do
    with true <- String.match?(digits, ~r/\A[0-9a-fA-F]+\z/),
         {value, ""} <- Integer.parse(digits, base) do
      value
    else
      _ -> :error
    end
  end

  # Dot hint: ParseFloat on the unchanged text. Only the plain decimal
  # form is mirrored; other digit forms are outside the subset.
  defp dot(<<?., c, _::binary>> = text) when c in ?0..?9 or c == ?_ do
    if Regex.match?(@dot_float, text), do: float(text), else: :reject
  end

  defp dot(text), do: {:str, text}

  # Correctly rounded float64. Large exponents and underflow of non-zero
  # digits are outside the subset (native turns overflow into a string).
  defp float(text) do
    %{"sign" => sign, "dot" => dot, "int" => int, "frac" => frac, "exp" => exp} =
      Regex.named_captures(@yaml_float, text)

    {int, frac} = if dot != "", do: {"0", dot}, else: {int, frac}
    frac = if frac == "", do: "0", else: frac
    exp = if exp == "", do: 0, else: String.to_integer(exp)

    case magnitude(int, frac, exp) do
      :zero -> {:float, String.to_float("#{sign}0.0")}
      m when m in -300..300 -> {:float, String.to_float("#{sign}#{int}.#{frac}e#{exp}")}
      _ -> :reject
    end
  end

  # Decimal exponent of the leading significant digit. Values whose magnitude
  # leaves +/-1e300 are outside the subset, so float64 never overflows or
  # silently underflows (native turns overflow into a string).
  defp magnitude(int, frac, exp) do
    case {String.trim_leading(int, "0"), String.trim_leading(frac, "0")} do
      {"", ""} -> :zero
      {"", significant} -> exp - (byte_size(frac) - byte_size(significant)) - 1
      {significant, _} -> exp + byte_size(significant) - 1
    end
  end
end
