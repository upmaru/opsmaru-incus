defmodule Opsmaru.Incus.NativeConfig do
  @moduledoc """
  Explicit pinned ConfigMap/DevicesMap JSON and YAML coercion, separate from
  lossless models.

  String, boolean, number and null config values become native strings. JSON
  numbers use the official decoder's float64 semantics, including integer
  precision loss. YAML is walked from yamerl's raw token stream so go-yaml v4
  semantics are applied where the native decoder applies them: plain
  untagged scalars resolve with the pinned resolver (base-0 integers,
  uint64 range, float64 'g' formatting, rejected timestamps), quoted and
  block scalars are always strings, explicit tags and anchors/aliases follow
  the native decoder, duplicate keys are rejected, merge keys are folded,
  and only the first document is decoded. Decoding into an existing map
  merges keys; a null document resets the target while an absent document
  leaves it untouched. Device updates merge individual properties.
  Unsupported arrays/nested values fail visibly. Inputs and results are
  bounded to 1 MiB and alias expansion is bounded in nodes and bytes; no
  backend, filesystem state or global configuration is involved.
  """
  alias Opsmaru.Incus.Error

  @limit 1_048_576
  # Alias fan-out bound: any document whose expanded node/byte count exceeds
  # these bounds would also produce a JSON result far beyond the 1 MiB limit,
  # so rejecting early preserves the native accept/reject decision.
  @max_expanded_nodes 1_000_000
  @max_expanded_bytes 2_000_000

  @min_int64 -9_223_372_036_854_775_808
  @max_int64 9_223_372_036_854_775_807
  @max_uint64 18_446_744_073_709_551_615
  @max_float_as_int 9_223_372_036_854_775_808

  @yaml_float ~r/\A[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?\z/

  # go-yaml v4 short tags after yamerl tag-handle expansion.
  @tag_str "tag:yaml.org,2002:str"
  @tag_int "tag:yaml.org,2002:int"
  @tag_float "tag:yaml.org,2002:float"
  @tag_bool "tag:yaml.org,2002:bool"
  @tag_null "tag:yaml.org,2002:null"
  @tag_binary "tag:yaml.org,2002:binary"
  @tag_merge "tag:yaml.org,2002:merge"
  @tag_timestamp "tag:yaml.org,2002:timestamp"

  # yamerl token records (deps/yamerl/include/yamerl_tokens.hrl) are read
  # through record accessors instead of hand-counted tuple positions.
  require Record

  Record.defrecordp(
    :scalarrec,
    Record.extract(:yamerl_scalar, from_lib: "yamerl/include/yamerl_tokens.hrl")
  )

  Record.defrecordp(
    :cstart,
    Record.extract(:yamerl_collection_start, from_lib: "yamerl/include/yamerl_tokens.hrl")
  )

  Record.defrecordp(
    :cend,
    Record.extract(:yamerl_collection_end, from_lib: "yamerl/include/yamerl_tokens.hrl")
  )

  Record.defrecordp(
    :anchor,
    Record.extract(:yamerl_anchor, from_lib: "yamerl/include/yamerl_tokens.hrl")
  )

  Record.defrecordp(
    :aliastok,
    Record.extract(:yamerl_alias, from_lib: "yamerl/include/yamerl_tokens.hrl")
  )

  Record.defrecordp(
    :tagtok,
    Record.extract(:yamerl_tag, from_lib: "yamerl/include/yamerl_tokens.hrl")
  )

  # Key under which the token_fun callback accumulates the stream for this
  # process; cleared again in the token_stream/1 after block.
  @token_key :"opsmaru.incus.native_config.tokens"

  def from_json(type, json, existing \\ nil) do
    with true <- type in ["ConfigMap", "DevicesMap"],
         true <- is_binary(json) and byte_size(json) <= @limit,
         {:ok, data} <- Jason.decode(json),
         :ok <- existing_map(type, existing),
         true <- existing_bytes(existing) <= @limit,
         {:ok, result} <- merge(type, data, existing),
         {:ok, encoded} <- Jason.encode(result),
         true <- byte_size(encoded) <= @limit do
      {:ok, result}
    else
      _ -> {:error, %Error{kind: :invalid_native_config}}
    end
  rescue
    _ -> {:error, %Error{kind: :invalid_native_config}}
  end

  def from_yaml(type, yaml, existing \\ nil) do
    with true <- type in ["ConfigMap", "DevicesMap"],
         true <- is_binary(yaml) and byte_size(yaml) <= @limit,
         :ok <- existing_map(type, existing),
         true <- existing_bytes(existing) <= @limit,
         {:ok, tokens} <- token_stream(yaml),
         {:ok, result} <- native_document(type, tokens, existing),
         {:ok, encoded} <- Jason.encode(result),
         true <- byte_size(encoded) <= @limit do
      {:ok, result}
    else
      _ -> {:error, %Error{kind: :invalid_native_config}}
    end
  end

  # ---------------------------------------------------------------------
  # Shared existing-target validation (JSON and YAML paths).
  # ---------------------------------------------------------------------

  defp existing_map(_, nil), do: :ok

  defp existing_map("ConfigMap", value) when is_map(value) do
    if map_size(value) <= 4096 and
         Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end),
       do: :ok,
       else: :error
  end

  defp existing_map("DevicesMap", value) when is_map(value) do
    if map_size(value) <= 4096 and
         Enum.all?(value, fn {key, item} ->
           is_binary(key) and existing_map("ConfigMap", item) == :ok
         end), do: :ok, else: :error
  end

  defp existing_map(_, _), do: :error

  defp existing_bytes(nil), do: 0
  defp existing_bytes(value) when is_binary(value), do: byte_size(value)

  defp existing_bytes(value) when is_map(value),
    do:
      Enum.reduce(value, 0, fn {key, item}, total ->
        total + byte_size(key) + existing_bytes(item)
      end)

  # ---------------------------------------------------------------------
  # JSON path.
  # ---------------------------------------------------------------------

  defp merge(_, nil, existing), do: {:ok, existing}

  defp merge(type, data, existing) when is_map(data) and map_size(data) <= 4096 do
    Enum.reduce_while(data, {:ok, existing || %{}}, fn {key, value}, {:ok, acc} ->
      result = if type == "ConfigMap", do: scalar(value), else: device(value, acc[key])

      case result do
        {:ok, native} when is_binary(key) -> {:cont, {:ok, Map.put(acc, key, native)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp merge(_, _, _), do: :error

  defp device(value, existing) when is_map(value), do: merge("ConfigMap", value, existing)
  defp device(_, _), do: :error
  defp scalar(nil), do: {:ok, ""}
  defp scalar(true), do: {:ok, "true"}
  defp scalar(false), do: {:ok, "false"}
  defp scalar(value) when is_binary(value), do: {:ok, value}

  defp scalar(value) when is_number(value) do
    float = value / 1

    cond do
      float >= -9_223_372_036_854_775_808 and float < 9_223_372_036_854_775_808 and
          float == trunc(float) ->
        {:ok, Integer.to_string(trunc(float))}

      float == 9_223_372_036_854_775_808 and arm64?() ->
        # Go's out-of-range float64 -> int64 conversion is architecture-specific.
        # ARM64 saturates to MaxInt64, whose float64 roundtrip equals 2^63;
        # AMD64 yields MinInt64 and therefore uses the scientific branch.
        {:ok, "9223372036854775807"}

      true ->
        {:ok, go_float(float)}
    end
  end

  defp scalar(_), do: :error

  # ---------------------------------------------------------------------
  # YAML: yamerl token stream with native go-yaml v4 semantics.
  #
  # Nodes are {:scalar, term, raw} where term is the go-yaml v4 resolved
  # value (:null | bool | integer | float | string | :timestamp | :merge |
  # :nan | :pos_inf | :neg_inf) and raw is the scalar's raw text, or
  # {:map, entries, merges} where entries is the explicit [{key, value}]
  # list with duplicates resolved and merges is the merge source node
  # (a mapping node or a {:seq, sources} node) or nil. Merge sources fill
  # keys the explicit entries do not set and are folded only where native
  # construction produces a plain map: result boundaries and merge-source
  # consumption. Anchored nodes keep their merge structure so alias
  # expansion charges every source, matching the native constructor.
  # duplicate keys resolved and merge keys folded in (explicit entries win,
  # then earlier merge sources).
  # ---------------------------------------------------------------------

  # Tokens are collected through yamerl's public token_fun option, which
  # calls the given 1-arity function for each token in stream order and
  # keeps it running while it returns :ok. The tokenizer reports
  # token-level syntax errors as a
  # {:yamerl_exception, [#yamerl_parsing_error, ...]} throw and nothing
  # else; no broad rescue is used in this path. The process-dictionary
  # list is bounded by the 1 MiB input limit and always cleared in the
  # after block.
  defp token_stream(yaml) do
    # NUL bytes make yamerl's scanner fail with a function clause instead of
    # its structured throw; the native scanner rejects them as invalid UTF-8.
    if :binary.match(yaml, <<0>>) == :nomatch do
      stream_tokens(yaml)
    else
      :error
    end
  end

  defp stream_tokens(yaml) do
    :erlang.put(@token_key, [])

    try do
      :yamerl_parser.string(yaml, [{:token_fun, &collect_token/1}])
      {:ok, :erlang.get(@token_key) |> Enum.reverse()}
    catch
      :throw, {:yamerl_exception, errors} when is_list(errors) -> :error
    after
      :erlang.erase(@token_key)
    end
  end

  defp collect_token(token) do
    :erlang.put(@token_key, [token | :erlang.get(@token_key)])
    :ok
  end

  defp native_document(type, [_stream_start | rest], existing) do
    ctx = %{
      type: type,
      tokens: rest,
      anchors: %{},
      in_progress: MapSet.new(),
      nodes: 0,
      bytes: 0,
      in_merge: false,
      in_merge_list: false
    }

    case skip_directives(ctx) do
      {:ok, ctx} -> first_document(ctx, existing)
      :error -> :error
    end
  end

  defp native_document(_type, _tokens, _existing), do: :error

  # %YAML 1.1-style and %TAG directives are accepted (yamerl validates the
  # version and expands the tag handles); reserved directives are not.
  # Only the 1.1 version directive is accepted (native: %YAML 1.1).
  defp skip_directives(%{tokens: [{:yamerl_yaml_directive, _l, _c, {1, 1}} | rest]} = ctx) do
    skip_directives(%{ctx | tokens: rest})
  end

  defp skip_directives(%{tokens: [{:yamerl_yaml_directive, _l, _c, _v} | _]}),
    do: :error

  defp skip_directives(%{tokens: [{:yamerl_tag_directive, _l, _c, _h, _p} | rest]} = ctx) do
    skip_directives(%{ctx | tokens: rest})
  end

  defp skip_directives(%{tokens: [{:yamerl_reserved_directive, _l, _c, _n, _a, _k} | _]}),
    do: :error

  defp skip_directives(ctx), do: {:ok, ctx}

  defp first_document(ctx, existing) do
    case ctx.tokens do
      # No document marker at all: the target is left untouched.
      [{:yamerl_stream_end, _l, _c} | _] ->
        {:ok, existing}

      [{:yamerl_doc_start, _l, _c, _version, _tags} | rest] ->
        ctx = %{ctx | tokens: rest}

        with {:ok, root, ctx} <- doc_root(ctx),
             {:ok, ctx} <- expect(ctx, :yamerl_doc_end) do
          native_result(ctx, root, existing)
        end

      _ ->
        :error
    end
  end

  # A document may carry no root node at all ("---"): that is a null
  # document and resets the target, unlike an absent document.
  defp doc_root(%{tokens: [{:yamerl_doc_end, _l, _c} | _]} = ctx), do: {:ok, :null, ctx}
  defp doc_root(ctx), do: parse_node(ctx, 0, :value)

  # A null document (absent root or a null scalar root) resets the target.
  defp native_result(_ctx, :null, _existing), do: {:ok, nil}
  defp native_result(_ctx, {:scalar, :null, _raw}, _existing), do: {:ok, nil}

  defp native_result(%{type: "ConfigMap"}, {:map, entries, merges}, existing) do
    with {:ok, folded} <- fold_node({:map, entries, merges}, :stringify),
         {:ok, value} <- native_values(folded) do
      {:ok, Map.merge(existing || %{}, value)}
    end
  end

  defp native_result(%{type: "DevicesMap"}, {:map, entries, merges}, existing) do
    with {:ok, folded} <- fold_node({:map, entries, merges}, :stringify) do
      fold_devices(folded, existing || %{})
    end
  end

  defp native_result(_ctx, _node, _existing), do: :error

  defp fold_devices(entries, acc) do
    Enum.reduce_while(entries, {:ok, acc}, fn {key, value}, {:ok, acc} ->
      case fold_device(value, Map.get(acc, key, %{})) do
        {:ok, device} -> {:cont, {:ok, Map.put(acc, key, device)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp fold_device({:map, inner, inner_merges}, device) do
    with {:ok, props_folded} <- fold_node({:map, inner, inner_merges}, :string_keys),
         {:ok, props} <- native_values(props_folded) do
      {:ok, Map.merge(device, props)}
    end
  end

  defp fold_device(_value, _device), do: :error

  # Value construction at a result boundary: scalars stringify natively,
  # any other shape (map, sequence, timestamp, failed tag) fails.
  defp native_values(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case value do
        {:scalar, term, _raw} ->
          case scalar_string(term) do
            {:ok, native} -> {:cont, {:ok, Map.put(acc, key, native)}}
            :error -> {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
  end

  # ---------------------------------------------------------------------
  # Node parser over the token stream.
  # ---------------------------------------------------------------------

  defp parse_node(ctx, depth, mode) do
    {anchor, tag, ctx} = take_props(ctx, nil, :none)

    case ctx.tokens do
      [t | _] when elem(t, 0) == :yamerl_alias ->
        name = token_text(aliastok(t, :name))
        ctx = drop(ctx)

        with {:ok, node, ctx} <- resolve_alias(ctx, name) do
          close_anchor(ctx, anchor, node)
        end

      [t | _] when elem(t, 0) == :yamerl_scalar ->
        ctx = drop(ctx)
        raw = token_text(scalarrec(t, :text))
        substyle = scalarrec(t, :substyle)
        tag = if tag == :none, do: tag_of(scalarrec(t, :tag)), else: tag

        with {:ok, ctx} <- charge(ctx, 1, byte_size(raw)) do
          case scalar_term(tag, substyle, raw) do
            {:ok, term} ->
              close_anchor(ctx, anchor, {:scalar, term, raw})

            # A tagged scalar that fails resolution is only an error when
            # it is actually constructed natively. Dropped values never
            # are, so keep the scalar unresolved and let a later
            # construction (an alias into a constructed position, a merge
            # without an override) fail on it.
            # Values are lazy while composing a dropped subtree or a merge
            # source; ctx.in_merge covers the merge-source case.
            :error when mode == :drop or ctx.in_merge ->
              close_anchor(ctx, anchor, {:scalar, :unresolved, raw})

            :error ->
              :error
          end
        end

      [t | _] when elem(t, 0) == :yamerl_collection_start ->
        kind = cstart(t, :kind)
        {anchor, ctx} = reattach_flow_anchor(anchor, ctx, t)
        parse_collection(ctx, depth, anchor, kind, mode)

      _ ->
        :error
    end
  end

  # yamerl emits the token for an anchor that precedes a flow collection in
  # the source after the collection's start and first item tokens; natively
  # the anchor belongs to the collection, so re-attach it. The token after
  # the entry key is by construction a first key scalar, so the captured
  # anchor cannot be one of a key scalar.
  defp reattach_flow_anchor(anchor, ctx, cstart) do
    {al, acol} = {elem(cstart, 1), elem(cstart, 2)}

    case ctx.tokens do
      # Flow mapping: start, first mapping key, anchor, key scalar.
      [t, mk, {:yamerl_anchor, al2, ac2, name}, key_node | rest]
      when elem(mk, 0) == :yamerl_mapping_key and {al2, ac2} < {al, acol} ->
        {token_text(name), %{ctx | tokens: [t, mk, key_node | rest]}}

      # Flow sequence: start, first entry, inner mapping start, first
      # mapping key, anchor, key scalar.
      [t, se, mc, mk, {:yamerl_anchor, al2, ac2, name}, key_node | rest]
      when elem(se, 0) == :yamerl_sequence_entry and elem(mc, 0) == :yamerl_collection_start and
             elem(mk, 0) == :yamerl_mapping_key and {al2, ac2} < {al, acol} ->
        {token_text(name), %{ctx | tokens: [t, se, mc, mk, key_node | rest]}}

      _ ->
        {anchor, ctx}
    end
  end

  defp parse_collection(ctx, depth, anchor, kind, :drop),
    do: compose_unchecked(drop(ctx), depth, anchor, kind)

  defp parse_collection(ctx, depth, anchor, :mapping, mode) do
    if collection_allowed?(ctx, depth, mode) do
      parse_checked_mapping(drop(ctx), depth, anchor)
    else
      # Sequences and deeper mappings are unsupported shapes.
      :error
    end
  end

  # Sequences and deeper mappings are unsupported shapes.
  defp parse_collection(_ctx, _depth, _anchor, _kind, _mode), do: :error

  # Entries keep their raw keys and duplicates; native applies the key and
  # duplicate checks when the mapping is constructed, so parsing must not
  # reject either. Checked and compose-only mappings differ only in scalar
  # resolution mode: dropped subtrees keep tag failures unresolved.
  defp parse_checked_mapping(ctx, depth, anchor) do
    with {:ok, entries, merges, ctx} <- parse_mapping(ctx, depth, :value),
         {:ok, ctx} <- expect(ctx, :yamerl_collection_end),
         {:ok, ctx} <- charge(ctx, 1, 0) do
      close_anchor(ctx, anchor, {:map, entries, merges})
    end
  end

  defp collection_allowed?(%{type: "DevicesMap"}, 1, :value), do: true
  # Merge sources construct into a map at any nesting depth, unlike regular
  # values whose shape is bounded to the two top levels.
  defp collection_allowed?(%{in_merge: true}, _depth, :value), do: true
  defp collection_allowed?(_ctx, 0, :value), do: true
  defp collection_allowed?(_ctx, _depth, _mode), do: false

  # A value whose key is dropped is composed fully but the entry is never
  # constructed: any shape composes and the result entry is dropped. The
  # composed node is still anchored, so aliases can reference its contents
  # later and natively construct them into the alias's target.
  defp compose_unchecked(ctx, depth, anchor, :mapping) do
    # Dropped values compose without shape or key validation; their
    # contents are only constructed (with the full key and duplicate
    # checks) through an alias or merge.
    with {:ok, entries, merges, ctx} <- parse_mapping(ctx, depth, :drop),
         {:ok, ctx} <- expect(ctx, :yamerl_collection_end),
         {:ok, ctx} <- charge(ctx, 1, 0) do
      close_anchor(ctx, anchor, {:map, entries, merges})
    end
  end

  defp compose_unchecked(ctx, depth, anchor, :sequence) do
    with {:ok, items, ctx} <- parse_sequence(ctx, depth),
         {:ok, ctx} <- expect(ctx, :yamerl_collection_end),
         {:ok, ctx} <- charge(ctx, 1, 0) do
      close_anchor(ctx, anchor, {:seq, items})
    end
  end

  # Folding a mapping node for construction: the explicit entries are
  # constructed against the target policy, then the merge sources fill keys
  # the explicit entries do not set (earlier source wins). Native applies
  # the key and duplicate checks when the node is constructed, so anchored
  # nodes keep their raw entries until this point and an alias or merge
  # that never constructs the node stays accepted.
  defp fold_node({:map, entries, nil}, policy), do: construct_entries(entries, policy)

  defp fold_node({:map, entries, source}, policy) do
    with {:ok, explicit} <- construct_entries(entries, policy) do
      fold_sources(merge_sources(source), explicit)
    end
  end

  defp merge_sources({:map, _entries, _merges} = node), do: [node]
  defp merge_sources({:seq, sources}), do: sources

  # Merge sources always construct into map[string]any, never the target
  # type, so their keys take the stringify policy regardless of where the
  # merge lands (root, device, or nested in another source).
  defp fold_sources(sources, explicit) do
    keys = explicit |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    case Enum.reduce_while(sources, {keys, []}, fn source, {keys, acc} ->
           with {:ok, src_entries} <- fold_node(source, :stringify),
                {keys, extra} <- fold_source_entries(src_entries, keys, []) do
             {:cont, {keys, extra ++ acc}}
           else
             _ -> {:halt, :error}
           end
         end) do
      {_keys, extra} -> {:ok, Enum.reverse(extra) ++ explicit}
      :error -> :error
    end
  end

  defp fold_source_entries(entries, keys, acc) do
    Enum.reduce_while(entries, {keys, acc}, fn {key, value}, {keys, acc} ->
      if MapSet.member?(keys, key) do
        {:cont, {keys, acc}}
      else
        {:cont, {MapSet.put(keys, key), [{key, value} | acc]}}
      end
    end)
  end

  # Key construction for a mapping: duplicate keys compare raw scalar text
  # (native compares the key nodes), null keys are dropped, timestamps and
  # failed tag resolution reject, and device property maps additionally
  # require string keys. Every other scalar key keeps its raw text.
  defp construct_entries(entries, policy) do
    case Enum.reduce_while(entries, {MapSet.new(), []}, fn entry, acc ->
           construct_entry(entry, policy, acc)
         end) do
      {_seen, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp construct_entry({_raw, :skip, _source}, _policy, {seen, acc}),
    do: {:cont, {seen, acc}}

  defp construct_entry({raw, term, value}, policy, {seen, acc}) do
    if MapSet.member?(seen, raw) do
      {:halt, :error}
    else
      seen = MapSet.put(seen, raw)

      cond do
        # Null keys fail device-property construction outright but drop
        # silently into map[string]any targets.
        term == :null and policy == :string_keys ->
          {:halt, :error}

        # Null keys and merge-tagged values drop their entry; the key text
        # still participates in duplicate detection.
        term == :null or is_nil(value) ->
          {:cont, {seen, acc}}

        true ->
          case map_key(raw, term, policy) do
            :error -> {:halt, :error}
            key -> {:cont, {seen, [{key, value} | acc]}}
          end
      end
    end
  end

  # Device property maps require string keys; map[string]any targets keep
  # the raw text of any scalar key (integers, floats, booleans and the
  # non-finite float markers all stringify to their raw form).
  defp map_key(_raw, :timestamp, _policy), do: :error
  defp map_key(_raw, :unresolved, _policy), do: :error

  defp map_key(raw, term, :stringify)
       when is_binary(term) or is_integer(term) or is_float(term) or is_boolean(term) or
              term in [:nan, :pos_inf, :neg_inf],
       do: raw

  defp map_key(raw, term, :string_keys) when is_binary(term), do: raw
  defp map_key(_raw, _term, _policy), do: :error

  defp parse_sequence(ctx, depth) do
    state =
      Enum.reduce_while(ctx.tokens, {ctx, []}, fn _token, {c, items} ->
        case c.tokens do
          [t | _] when elem(t, 0) == :yamerl_collection_end ->
            if cend(t, :kind) == :sequence do
              {:halt, {:done, c, Enum.reverse(items)}}
            else
              {:halt, :error}
            end

          [{:yamerl_sequence_entry, _l, _c} | _] ->
            case parse_node(drop(c), depth + 1, :drop) do
              {:ok, item, c2} -> {:cont, {c2, [item | items]}}
              :error -> {:halt, :error}
            end

          _ ->
            {:halt, :error}
        end
      end)

    case state do
      {:done, c, items} -> {:ok, items, c}
      _ -> :error
    end
  end

  defp take_props(%{tokens: [t | rest]} = ctx, _anchor, tag) when elem(t, 0) == :yamerl_anchor do
    name = token_text(anchor(t, :name))
    take_props(%{ctx | tokens: rest}, name, tag)
  end

  defp take_props(%{tokens: [t | rest]} = ctx, anchor, _tag) when elem(t, 0) == :yamerl_tag do
    uri = tag_of(tagtok(t, :uri))
    take_props(%{ctx | tokens: rest}, anchor, uri)
  end

  defp take_props(ctx, anchor, tag), do: {anchor, tag, ctx}

  defp close_anchor(ctx, nil, node), do: {:ok, node, ctx}

  defp close_anchor(%{in_progress: in_progress, anchors: anchors} = ctx, name, node) do
    if MapSet.member?(in_progress, name) do
      # An anchor nested inside itself: the native composer rejects it.
      :error
    else
      ctx = %{
        ctx
        | in_progress: MapSet.delete(in_progress, name),
          anchors: Map.put(anchors, name, node)
      }

      {:ok, node, ctx}
    end
  end

  # The tokenizer accepts undefined and forward aliases; the native
  # composer rejects both, and cycles are rejected by construction.
  defp resolve_alias(
         %{in_progress: in_progress, anchors: anchors, in_merge_list: in_merge_list} = ctx,
         name
       ) do
    if MapSet.member?(in_progress, name) do
      :error
    else
      case Map.fetch(anchors, name) do
        # A sequence anchor is not a valid merge source natively, even
        # when its items are all mappings.
        {:ok, {:seq, _items}} when in_merge_list ->
          :error

        {:ok, node} ->
          with {:ok, ctx} <- expand(node, ctx) do
            {:ok, node, ctx}
          end

        :error ->
          :error
      end
    end
  end

  defp parse_mapping(ctx, depth, mode) do
    state =
      Enum.reduce_while(ctx.tokens, {ctx, [], nil}, fn _token, {c, entries, merges} ->
        case c.tokens do
          [t | _] when elem(t, 0) == :yamerl_collection_end ->
            if cend(t, :kind) == :mapping do
              {:halt, {:done, c, Enum.reverse(entries), merges}}
            else
              # A mismatched end token is invalid for well-formed input;
              # treat it as such instead of trusting the stream.
              {:halt, :error}
            end

          _ ->
            case parse_entry(c, depth, merges, mode) do
              {:ok, c2, entry, merges2} -> {:cont, {c2, [entry | entries], merges2}}
              :error -> {:halt, :error}
            end
        end
      end)

    case state do
      {:done, c, entries, merges} -> {:ok, entries, merges, c}
      _ -> :error
    end
  end

  defp parse_entry(
         %{tokens: [{:yamerl_mapping_key, _l, _c} | rest]} = ctx,
         depth,
         merges,
         mode
       ) do
    ctx = %{ctx | tokens: rest}

    key_mode = if mode == :drop, do: :drop, else: :key

    case parse_node(ctx, depth + 1, key_mode) do
      {:ok, {:scalar, :merge, raw}, ctx} ->
        merge_key_entry(ctx, raw, depth, merges)

      {:ok, {:scalar, :null, raw}, ctx} ->
        dropped_key_entry(ctx, raw, depth, merges)

      {:ok, {:scalar, term, raw}, ctx} ->
        value_entry(ctx, raw, term, depth, merges, mode)

      _ ->
        :error
    end
  end

  defp parse_entry(_ctx, _depth, _merges, _mode), do: :error

  defp merge_key_entry(ctx, raw, depth, nil) do
    with {:ok, ctx} <- expect(ctx, :yamerl_mapping_value),
         {:ok, source, ctx} <- parse_merge_source(ctx, depth) do
      {:ok, ctx, {raw, :skip, source}, source}
    end
  end

  # A second merge key is a duplicate-key error natively.
  defp merge_key_entry(_ctx, _raw, _depth, _merges), do: :error

  defp dropped_key_entry(ctx, raw, depth, merges) do
    # A null key fails string construction and is dropped natively; its
    # value still composes (aliases must resolve) but is never constructed,
    # so any shape is accepted. The entry keeps its raw key so duplicate
    # null keys still reject when the mapping is constructed.
    with {:ok, ctx} <- expect(ctx, :yamerl_mapping_value),
         {:ok, _value, ctx} <- parse_node(ctx, depth + 1, :drop) do
      {:ok, ctx, {raw, :null, nil}, merges}
    end
  end

  defp value_entry(ctx, raw, term, depth, merges, mode) do
    with {:ok, ctx} <- expect(ctx, :yamerl_mapping_value),
         {:ok, value, ctx} <- parse_node(ctx, depth + 1, mode) do
      if merge_value?(value) do
        # constructMerge always fails; the entry is dropped.
        {:ok, ctx, {raw, term, nil}, merges}
      else
        {:ok, ctx, {raw, term, value}, merges}
      end
    end
  end

  defp merge_value?({:scalar, :merge, _raw}), do: true
  defp merge_value?(_value), do: false

  # Aliases resolve to their target during parse_node; a merge value must
  # be a mapping or a sequence of mappings (anything else, including
  # sequence aliases to non-maps, is rejected natively). Sources are parsed
  # with in_merge set so their null keys are dropped like native
  # direct-construction drops them.
  # Merge sources construct into map[string]any, not the target type, so
  # their null keys drop; the flag must not leak into the entries that
  # follow the merge, so it is restored from the caller's value.
  defp parse_merge_source(ctx, depth) do
    in_merge = ctx.in_merge
    ctx = Map.put(ctx, :in_merge, true)

    result =
      case ctx.tokens do
        [t | _] when elem(t, 0) == :yamerl_collection_start ->
          if cstart(t, :kind) == :sequence do
            parse_merge_sequence(drop(ctx), depth, [])
          else
            parse_merge_mapping(ctx, depth)
          end

        _ ->
          parse_merge_mapping(ctx, depth)
      end

    case result do
      {:ok, source, ctx} -> {:ok, source, Map.put(ctx, :in_merge, in_merge)}
      :error -> :error
    end
  end

  defp parse_merge_mapping(ctx, depth) do
    case parse_node(ctx, depth, :value) do
      {:ok, {:map, _entries, _merges} = node, ctx} -> {:ok, node, ctx}
      # A sequence of mappings merges only when written literally; natively
      # an alias to a sequence is not a valid merge source.
      {:ok, {:seq, _items}, _ctx} -> :error
      {:ok, _node, _ctx} -> :error
      :error -> :error
    end
  end

  defp parse_merge_sequence(%{tokens: [t | _]} = ctx, depth, sources) do
    # An alias to a sequence is not a merge source natively; the flag lets
    # resolve_alias/2 reject it without changing normal alias semantics.
    ctx = Map.put(ctx, :in_merge_list, true)

    cond do
      elem(t, 0) == :yamerl_sequence_entry ->
        case parse_node(drop(ctx), depth, :value) do
          {:ok, {:map, _entries, _merges} = node, ctx} ->
            parse_merge_sequence(ctx, depth, [node | sources])

          _ ->
            :error
        end

      elem(t, 0) == :yamerl_collection_end and cend(t, :kind) == :sequence ->
        ctx = Map.put(ctx, :in_merge_list, false)
        {:ok, {:seq, Enum.reverse(sources)}, drop(ctx)}

      true ->
        :error
    end
  end

  # Token string fields are charlists of unicode codepoints.
  defp token_text(data) when is_binary(data), do: data
  defp token_text(data), do: List.to_string(data)

  # ---------------------------------------------------------------------
  # go-yaml v4 scalar resolution and native stringification.
  # ---------------------------------------------------------------------

  defp scalar_term(tag, substyle, raw) do
    cond do
      substyle == :plain and reserved_indicator?(raw) ->
        # yamerl tolerates leading @/` with a warning; the native scanner
        # rejects them.
        :error

      substyle != :plain and tag == :none ->
        # Quoted and block scalars are always strings.
        {:ok, raw}

      tag == :none ->
        resolve_plain(raw)

      true ->
        explicit_term(tag, raw)
    end
  end

  defp explicit_term(@tag_str, raw), do: {:ok, raw}
  defp explicit_term(@tag_int, raw), do: explicit_int(raw)
  defp explicit_term(@tag_float, raw), do: explicit_float(raw)
  defp explicit_term(@tag_bool, raw), do: explicit_bool(raw)
  defp explicit_term(@tag_null, raw), do: explicit_null(raw)
  defp explicit_term(@tag_binary, raw), do: explicit_binary(raw)
  defp explicit_term(@tag_merge, _raw), do: {:ok, :merge}

  defp explicit_term(@tag_timestamp, raw),
    do: if(yaml_timestamp?(raw), do: {:ok, :timestamp}, else: :error)

  # Unknown/custom tags construct to their raw text natively.
  defp explicit_term(_tag, raw), do: {:ok, raw}

  defp reserved_indicator?(raw) do
    case raw do
      <<?@, _::binary>> -> true
      <<?`, _::binary>> -> true
      _ -> false
    end
  end

  # go-yaml v4 resolves exact-match strings before any numeric parsing and
  # dispatches the rest by the first character's hint class. Non-finite
  # floats are marker terms: the native decoder formats them to
  # "NaN"/"+Inf"/"-Inf" and they never surface as numbers.
  # Exact-match table from the native resolver, tried before any numeric
  # parsing.
  @plain_literals %{
    "" => :null,
    "~" => :null,
    "null" => :null,
    "Null" => :null,
    "NULL" => :null,
    "true" => true,
    "True" => true,
    "TRUE" => true,
    "false" => false,
    "False" => false,
    "FALSE" => false,
    ".nan" => :nan,
    ".NaN" => :nan,
    ".NAN" => :nan,
    ".inf" => :pos_inf,
    ".Inf" => :pos_inf,
    ".INF" => :pos_inf,
    "+.inf" => :pos_inf,
    "+.Inf" => :pos_inf,
    "+.INF" => :pos_inf,
    "-.inf" => :neg_inf,
    "-.Inf" => :neg_inf,
    "-.INF" => :neg_inf,
    "-0" => -0.0,
    "-0.0" => -0.0,
    "<<" => :merge
  }

  defp resolve_plain(raw) do
    if Map.has_key?(@plain_literals, raw) do
      {:ok, Map.fetch!(@plain_literals, raw)}
    else
      resolve_hinted(raw, raw_hint(raw))
    end
  end

  # First-character hint classes from the native resolver table.
  defp raw_hint(<<c, _::binary>>) when c in ?0..?9 or c == ?+ or c == ?-, do: :numeric
  defp raw_hint(<<?., _::binary>>), do: :dot_float
  defp raw_hint(<<c, _::binary>>) when c in ~c"yYnNtTfFoO~<", do: :string
  defp raw_hint(_), do: :string

  defp resolve_hinted(raw, :numeric) do
    # Timestamps are tried on the original text before numeric parsing;
    # underscores are stripped for int and float (native order).
    plain = String.replace(raw, "_", "")

    if yaml_timestamp?(raw) do
      # time.Time is unsupported in ConfigMap/DevicesMap values.
      {:ok, :timestamp}
    else
      case go_base0_int(plain) do
        {:ok, int} -> {:ok, int}
        :error -> go_plain_float(raw, plain)
      end
    end
  end

  defp resolve_hinted(raw, :dot_float) do
    # Dot-leading scalars try ParseFloat on the raw text only (underscores
    # between digits included); there is no int or timestamp fallback.
    case go_parse_float(raw) do
      {:ok, float} -> {:ok, float}
      :error -> {:ok, raw}
    end
  end

  defp resolve_hinted(raw, :string), do: {:ok, raw}

  defp go_plain_float(raw, plain) do
    if String.match?(plain, @yaml_float) do
      parse_float_text(plain) |> ok_or_raw(raw)
    else
      {:ok, raw}
    end
  end

  # Elixir's Float.parse requires a leading digit before the point; the
  # leading-dot YAML forms are parsed with a zero inserted. Elixir's parser
  # reports overflow as an error, so accepted results are always finite.
  defp parse_float_text(text) do
    {sign, body} =
      case text do
        "-" <> r -> {"-", r}
        "+" <> r -> {"", r}
        _ -> {"", text}
      end

    body = if String.starts_with?(body, "."), do: "0" <> body, else: body

    # Go accepts a trailing dot before the exponent or at end of input;
    # Elixir's parser leaves the dot unparsed, so insert a zero.
    body = String.replace(body, ~r/\.([eE]|$)/, ".0\\1")

    case Float.parse(sign <> body) do
      {float, ""} when is_float(float) -> {:ok, float}
      _ -> :error
    end
  end

  defp ok_or_raw({:ok, value}, _raw), do: {:ok, value}
  defp ok_or_raw(:error, raw), do: {:ok, raw}

  # Go strconv.ParseFloat(text, 64) for dot-leading floats: at most one
  # dot, digits and underscores (only between digits), an optional e/E
  # exponent with at least one digit, and the whole input consumed.
  defp go_parse_float(raw) do
    cs = String.to_charlist(raw) |> List.to_tuple()
    n = tuple_size(cs)

    if read_float(cs, 0, n) == {:ok, n} and underscore_ok?(cs, n) do
      parse_float_text(String.replace(raw, "_", ""))
    else
      :error
    end
  end

  defp read_float(cs, i, n) do
    case read_mantissa(cs, i, n, false, false) do
      {j, true} -> read_exp(cs, j, n)
      _ -> :error
    end
  end

  defp read_mantissa(_cs, i, n, sawdigits, _sawdot) when i >= n, do: {i, sawdigits}

  defp read_mantissa(cs, i, n, sawdigits, sawdot) do
    c = :erlang.element(i + 1, cs)

    cond do
      c == ?_ -> read_mantissa(cs, i + 1, n, sawdigits, sawdot)
      c == ?. and not sawdot -> read_mantissa(cs, i + 1, n, sawdigits, true)
      c in ?0..?9 -> read_mantissa(cs, i + 1, n, true, sawdot)
      true -> {i, sawdigits}
    end
  end

  defp read_exp(cs, i, n) do
    if i < n and :erlang.element(i + 1, cs) in [?e, ?E] do
      j = if(i + 2 < n and :erlang.element(i + 2, cs) in [?+, ?-], do: i + 2, else: i + 1)
      read_exp_digits(cs, j, n, false)
    else
      {:ok, i}
    end
  end

  # At least one exponent digit is required; end of input ends the scan
  # once the digits have been seen (Go's readFloat accepts e2 at EOL).
  # At least one exponent digit is required; end of input ends the scan
  # once a digit has been seen (Go's readFloat accepts e2 at EOL).
  defp read_exp_digits(_cs, i, n, true) when i >= n, do: {:ok, n}
  defp read_exp_digits(_cs, i, n, false) when i >= n, do: :error

  defp read_exp_digits(cs, i, n, sawdigit) do
    c = :erlang.element(i + 1, cs)

    cond do
      c == ?_ -> read_exp_digits(cs, i + 1, n, sawdigit)
      c in ?0..?9 -> read_exp_digits(cs, i + 1, n, true)
      true -> {:ok, i}
    end
  end

  # Go strconv.ParseFloat underscore validation: an underscore must not be
  # first or last and must follow a digit or letter; the flag resets after
  # every underscore and every other character, so a rejected underscore
  # stays rejected even when later digits appear.
  defp underscore_ok?(cs, n) do
    case Enum.reduce_while(0..(n - 1), false, fn idx, saw ->
           c = :erlang.element(idx + 1, cs)

           cond do
             c in ?0..?9 or c in ?a..?z or c in ?A..?Z ->
               {:cont, true}

             c == ?_ and idx > 0 and idx < n - 1 and saw ->
               {:cont, false}

             c == ?_ ->
               {:halt, :error}

             true ->
               {:cont, false}
           end
         end) do
      :error -> false
      _ -> true
    end
  end

  # Go strconv.ParseInt(plain, 0, 64) followed by ParseUint(plain, 0, 64).
  defp go_base0_int(text) do
    {sign, body} =
      case text do
        "+" <> r -> {1, r}
        "-" <> r -> {-1, r}
        _ -> {1, text}
      end

    if body == "0" do
      {:ok, 0}
    else
      with {base, digits} <- split_base0(body),
           {:ok, magnitude} <- go_digits(digits, base) do
        apply_int_range(sign, magnitude)
      end
    end
  end

  defp split_base0("0b" <> r), do: {2, r}
  defp split_base0("0B" <> r), do: {2, r}
  defp split_base0("0x" <> r), do: {16, r}
  defp split_base0("0X" <> r), do: {16, r}
  defp split_base0("0o" <> r), do: {8, r}
  defp split_base0("0O" <> r), do: {8, r}
  defp split_base0("0" <> r), do: {8, r}
  defp split_base0(digits), do: {10, digits}

  # Go int64 range first, then the uint64 range for non-negative values.
  defp apply_int_range(1, magnitude) when magnitude <= @max_int64, do: {:ok, magnitude}
  defp apply_int_range(-1, magnitude) when magnitude <= -@min_int64, do: {:ok, -magnitude}
  defp apply_int_range(1, magnitude) when magnitude <= @max_uint64, do: {:ok, magnitude}
  defp apply_int_range(_sign, _magnitude), do: :error

  # Callers strip underscores first (native behavior), so only the digit
  # validity and the uint64 overflow bound remain to check.
  defp go_digits(digits, base) do
    ok =
      digits != "" and
        Enum.all?(String.to_charlist(digits), &(not is_nil(go_digit_value(&1, base))))

    if ok do
      Enum.reduce_while(
        String.to_charlist(digits),
        {:ok, 0},
        fn cp, {:ok, acc} ->
          value = acc * base + go_digit_value(cp, base)
          if value > @max_uint64, do: {:halt, :error}, else: {:cont, {:ok, value}}
        end
      )
    else
      :error
    end
  end

  defp go_digit_value(cp, base) do
    value =
      cond do
        cp in ?0..?9 -> cp - ?0
        base >= 16 and cp in ?a..?f -> cp - ?a + 10
        base >= 16 and cp in ?A..?F -> cp - ?A + 10
        true -> nil
      end

    if value != nil and value < base, do: value, else: nil
  end

  # The exact-match resolve table resolves before numeric parsing; an entry
  # whose resolved tag differs from the explicit tag is a resolver failure.
  defp resolved_map_entry?(raw) do
    raw in [
      "",
      "~",
      "null",
      "Null",
      "NULL",
      "true",
      "True",
      "TRUE",
      "false",
      "False",
      "FALSE",
      ".nan",
      ".NaN",
      ".NAN",
      ".inf",
      ".Inf",
      ".INF",
      "+.inf",
      "+.Inf",
      "+.INF",
      "-.inf",
      "-.Inf",
      "-.INF",
      "-0",
      "-0.0",
      "<<"
    ]
  end

  defp explicit_int(raw) do
    if resolved_map_entry?(raw), do: :error, else: go_base0_int(String.replace(raw, "_", ""))
  end

  defp explicit_float(raw) do
    cond do
      raw in [".nan", ".NaN", ".NAN"] -> {:ok, :nan}
      raw in [".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF"] -> {:ok, :pos_inf}
      raw in ["-.inf", "-.Inf", "-.INF"] -> {:ok, :neg_inf}
      raw in ["-0", "-0.0"] -> {:ok, -0.0}
      resolved_map_entry?(raw) -> :error
      true -> explicit_float_numeric(raw)
    end
  end

  defp explicit_float_numeric(raw) do
    case raw_hint(raw) do
      :numeric ->
        plain = String.replace(raw, "_", "")

        case go_base0_int(plain) do
          {:ok, int} ->
            {:ok, int / 1}

          :error ->
            if String.match?(plain, @yaml_float), do: parse_float_text(plain), else: :error
        end

      :dot_float ->
        go_parse_float(raw)

      _ ->
        :error
    end
  end

  defp explicit_bool(raw) do
    case raw do
      "true" -> {:ok, true}
      "True" -> {:ok, true}
      "TRUE" -> {:ok, true}
      "false" -> {:ok, false}
      "False" -> {:ok, false}
      "FALSE" -> {:ok, false}
      _ -> :error
    end
  end

  defp explicit_null(raw) do
    case raw do
      "" -> {:ok, :null}
      "~" -> {:ok, :null}
      "null" -> {:ok, :null}
      "Null" -> {:ok, :null}
      "NULL" -> {:ok, :null}
      _ -> :error
    end
  end

  defp explicit_binary(raw) do
    case Base.decode64(raw, global: true) do
      {:ok, decoded} ->
        if String.valid?(decoded), do: {:ok, decoded}, else: :error

      _ ->
        :error
    end
  end

  # fromMapStringAny: null -> "", bool -> FormatBool, int/uint64 -> decimal,
  # float64 -> integer form when lossless else 'g' -1 64, string unchanged.
  defp scalar_string(:null), do: {:ok, ""}
  defp scalar_string(true), do: {:ok, "true"}
  defp scalar_string(false), do: {:ok, "false"}
  defp scalar_string(:nan), do: {:ok, "NaN"}
  defp scalar_string(:pos_inf), do: {:ok, "+Inf"}
  defp scalar_string(:neg_inf), do: {:ok, "-Inf"}
  defp scalar_string(:timestamp), do: :error
  defp scalar_string(:merge), do: :error
  defp scalar_string(:unresolved), do: :error
  defp scalar_string(integer) when is_integer(integer), do: {:ok, Integer.to_string(integer)}

  defp scalar_string(float) when is_float(float) do
    cond do
      float >= @min_int64 and float < @max_float_as_int and float == trunc(float) ->
        {:ok, Integer.to_string(trunc(float))}

      float == @max_float_as_int and arm64?() ->
        # Same architecture-specific saturation special case as scalar/1.
        {:ok, "9223372036854775807"}

      true ->
        {:ok, go_float(float)}
    end
  end

  defp scalar_string(binary) when is_binary(binary), do: {:ok, binary}
  defp scalar_string(_), do: :error

  # go-yaml v4 resolves plain scalars matching its timestamp formats to
  # time.Time, which ConfigMap/DevicesMap reject.
  defp yaml_timestamp?(value) when is_binary(value),
    do: timestamp_t?(value) or timestamp_space?(value) or timestamp_date?(value)

  defp timestamp_t?(value) do
    with %{} = caps <-
           Regex.named_captures(
             ~r/\A(?<y>[0-9]{4})-(?<m>[0-9]{1,2})-(?<d>[0-9]{1,2})[Tt](?<h>[0-9]{1,2}):(?<min>[0-9]{1,2}):(?<s>[0-9]{1,2})(?:\.[0-9]+)?(?:Z|[+-](?<th>[0-9]{2}):(?<tm>[0-9]{2}))\z/,
             value
           ),
         true <- yaml_date_ok?(caps) and yaml_time_ok?(caps) and yaml_tz_ok?(caps) do
      true
    else
      _ -> false
    end
  end

  defp timestamp_space?(value) do
    with %{} = caps <-
           Regex.named_captures(
             ~r/\A(?<y>[0-9]{4})-(?<m>[0-9]{1,2})-(?<d>[0-9]{1,2}) (?<h>[0-9]{1,2}):(?<min>[0-9]{1,2}):(?<s>[0-9]{1,2})(?:\.[0-9]+)?\z/,
             value
           ),
         true <- yaml_date_ok?(caps) and yaml_time_ok?(caps) do
      true
    else
      _ -> false
    end
  end

  defp timestamp_date?(value) do
    with %{} = caps <-
           Regex.named_captures(~r/\A(?<y>[0-9]{4})-(?<m>[0-9]{1,2})-(?<d>[0-9]{1,2})\z/, value),
         true <- yaml_date_ok?(caps) do
      true
    else
      _ -> false
    end
  end

  defp yaml_date_ok?(caps) do
    month = String.to_integer(caps["m"])
    day = String.to_integer(caps["d"])
    month in 1..12 and day in 1..days_in_month(String.to_integer(caps["y"]), month)
  end

  defp yaml_time_ok?(caps),
    do:
      String.to_integer(caps["h"]) in 0..23 and
        String.to_integer(caps["min"]) in 0..59 and String.to_integer(caps["s"]) in 0..59

  # Go time.Parse accepts offsets up to 24 hours and 60 minutes.
  defp yaml_tz_ok?(caps) do
    case caps["th"] do
      nil -> true
      "" -> true
      th -> String.to_integer(th) <= 24 and String.to_integer(caps["tm"]) <= 60
    end
  end

  defp days_in_month(year, 2) do
    leap = rem(year, 4) == 0 and (rem(year, 100) != 0 or rem(year, 400) == 0)
    if leap, do: 29, else: 28
  end

  defp days_in_month(_year, month) when month in [4, 6, 9, 11], do: 30
  defp days_in_month(_year, _month), do: 31

  # ---------------------------------------------------------------------
  # Walker bookkeeping.
  # ---------------------------------------------------------------------

  # yamerl expands "!!name" handles to tag:yaml.org,2002:name; custom
  # handles stay verbatim. Non-specific tags mean "untagged".
  defp tag_of({:yamerl_tag, _line, _col, _uri} = t), do: tag_of(tagtok(t, :uri))

  defp tag_of({:non_specific, _}), do: :none
  defp tag_of(uri) when is_list(uri), do: List.to_string(uri)

  defp drop(%{tokens: [_head | rest]} = ctx), do: %{ctx | tokens: rest}

  defp expect(%{tokens: [token | rest]} = ctx, name) when elem(token, 0) == name,
    do: {:ok, %{ctx | tokens: rest}}

  defp expect(_ctx, _name), do: :error

  defp charge(%{nodes: nodes, bytes: bytes} = ctx, add_nodes, add_bytes) do
    if nodes + add_nodes > @max_expanded_nodes or bytes + add_bytes > @max_expanded_bytes,
      do: :error,
      else: {:ok, %{ctx | nodes: nodes + add_nodes, bytes: bytes + add_bytes}}
  end

  # Aliases expand eagerly (native behavior); the expansion budget bounds
  # alias fan-out so bombs fail fast instead of materializing. Charged bytes
  # track the value materialization a result encode would require. Sequence
  # anchors can only exist under dropped values, where native construction
  # of the alias target fails, so they are rejected.
  # Expansion re-walks the anchored node exactly as the native constructor
  # would, so merge sources are charged with every alias: that fan-out is
  # what turns an anchored merge chain into an expansion bomb.
  defp expand(node, ctx) do
    case node do
      {:scalar, _term, raw} ->
        charge(ctx, 1, byte_size(raw))

      {:map, entries, merges} ->
        # Merge-key entries carry the source node, charged by expand_merge;
        # dropped entries (nil values) were charged at parse time.
        values =
          for {_raw, term, value} <- entries, term != :skip and not is_nil(value), reduce: [] do
            acc -> [value | acc]
          end

        with {:ok, ctx} <- charge(ctx, 1, 0),
             {:ok, ctx} <- expand_items(values, ctx) do
          expand_merge(merges, ctx)
        end

      {:seq, items} ->
        with {:ok, ctx} <- charge(ctx, 1, 0) do
          expand_items(items, ctx)
        end
    end
  end

  defp expand_items([], ctx), do: {:ok, ctx}

  defp expand_items([item | rest], ctx) do
    with {:ok, ctx} <- expand(item, ctx) do
      expand_items(rest, ctx)
    end
  end

  defp expand_merge(nil, ctx), do: {:ok, ctx}

  defp expand_merge(source, ctx) do
    expand(source, ctx)
  end

  defp arm64?,
    do:
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.starts_with?(["aarch64", "arm64"])

  # strconv.FormatFloat('g', -1, 64): shortest representation; scientific
  # notation below 1e-4 or at/above 1e6, with signed two-digit exponents.
  defp go_float(float) do
    case String.split(:erlang.float_to_binary(float, [:short]), "e") do
      [decimal] ->
        if abs(float) >= 1_000_000 do
          {sign, decimal} =
            if String.starts_with?(decimal, "-"),
              do: {"-", String.trim_leading(decimal, "-")},
              else: {"", decimal}

          [whole, fraction] = String.split(decimal, ".")
          digits = whole <> fraction

          sign <>
            binary_part(digits, 0, 1) <>
            "." <>
            binary_part(digits, 1, byte_size(digits) - 1) <>
            "e+" <> String.pad_leading(Integer.to_string(byte_size(whole) - 1), 2, "0")
        else
          decimal
        end

      [mantissa, exponent] ->
        exponent = String.to_integer(exponent)
        mantissa = String.replace_suffix(mantissa, ".0", "")

        if exponent < -4 or exponent >= 6 do
          mantissa <>
            "e" <>
            if(exponent < 0, do: "-", else: "+") <>
            String.pad_leading(Integer.to_string(abs(exponent)), 2, "0")
        else
          {sign, mantissa} =
            if String.starts_with?(mantissa, "-"),
              do: {"-", String.trim_leading(mantissa, "-")},
              else: {"", mantissa}

          digits = String.replace(mantissa, ".", "")
          point = exponent + 1

          sign <>
            cond do
              point <= 0 ->
                "0." <> String.duplicate("0", -point) <> digits

              point >= byte_size(digits) ->
                digits <> String.duplicate("0", point - byte_size(digits))

              true ->
                binary_part(digits, 0, point) <>
                  "." <> binary_part(digits, point, byte_size(digits) - point)
            end
        end
    end
  end
end
