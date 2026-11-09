defmodule Opsmaru.Incus.SFTP.Path do
  @moduledoc """
  Go `path` semantics used by the pinned `pkg/sftp` client: `join/1`, `split/1`,
  `clean/1` and `match/2`. Paths are byte strings with `/` separators; nothing here
  touches a filesystem.
  """

  @doc "Go `path.Join`: joins non-empty elements with `/` and cleans the result."
  def join(elements) when is_list(elements) do
    case Enum.drop_while(elements, &(&1 == "")) do
      [] -> ""
      rest -> clean(Enum.join(rest, "/"))
    end
  end

  @doc "Go `path.Split`: splits after the final `/` into `{dir, file}`."
  def split(path) when is_binary(path) do
    case :binary.matches(path, "/") do
      [] ->
        {"", path}

      matches ->
        {index, 1} = List.last(matches)
        <<dir::binary-size(index + 1), file::binary>> = path
        {dir, file}
    end
  end

  @doc "Go `path.Clean`: the shortest equivalent path by purely lexical processing."
  def clean(""), do: "."

  def clean(path) when is_binary(path) do
    rooted = String.starts_with?(path, "/")

    parts =
      path
      |> :binary.split("/", [:global])
      |> Enum.reduce([], fn
        part, stack when part in ["", "."] -> stack
        "..", [top | rest] when top != ".." -> rest
        "..", [] when rooted -> []
        part, stack -> [part | stack]
      end)
      |> Enum.reverse()
      |> Enum.join("/")

    case {rooted, parts} do
      {true, _} -> "/" <> parts
      {false, ""} -> "."
      {false, _} -> parts
    end
  end

  @doc false
  def meta?(path), do: String.contains?(path, ["\\", "*", "?", "["])

  @doc """
  Go `path.Match`: whether `name` matches the shell `pattern`. Returns
  `{:ok, boolean}` or `{:error, :bad_pattern}` exactly where Go returns
  `path.ErrBadPattern`.
  """
  def match(pattern, name) when is_binary(pattern) and is_binary(name),
    do: match_pattern(pattern, name)

  defp match_pattern(<<>>, name), do: {:ok, name == <<>>}

  defp match_pattern(pattern, name) do
    {star, chunk, pattern} = scan_chunk(pattern)

    if star and chunk == <<>>,
      do: {:ok, not String.contains?(name, "/")},
      else: continue_match(star, chunk, name, pattern)
  end

  defp continue_match(star, chunk, name, pattern) do
    case match_chunk(chunk, name) do
      {:ok, rest} when rest == <<>> or pattern != <<>> ->
        match_pattern(pattern, rest)

      {:error, _} = error ->
        error

      _ ->
        with :retry <- if(star, do: match_star(chunk, name, pattern, 0), else: :retry),
             do: validate_rest(pattern)
    end
  end

  # A star may skip leading bytes of name, but never a `/`.
  defp match_star(chunk, name, pattern, index) do
    if index < byte_size(name) and :binary.at(name, index) != ?/ do
      <<_::binary-size(index + 1), rest::binary>> = name

      case match_chunk(chunk, rest) do
        {:ok, rest} when pattern == <<>> and rest != <<>> ->
          match_star(chunk, name, pattern, index + 1)

        {:ok, rest} ->
          match_pattern(pattern, rest)

        {:error, _} = error ->
          error

        :nomatch ->
          match_star(chunk, name, pattern, index + 1)
      end
    else
      :retry
    end
  end

  # Before returning false, the remaining pattern must still be well formed.
  defp validate_rest(<<>>), do: {:ok, false}

  defp validate_rest(pattern) do
    {_, chunk, pattern} = scan_chunk(pattern)

    case match_chunk(chunk, <<>>) do
      {:error, _} = error -> error
      _ -> validate_rest(pattern)
    end
  end

  defp scan_chunk(pattern) do
    {star, pattern} = skip_stars(pattern, false)
    index = scan(pattern, 0, false)
    <<chunk::binary-size(index), rest::binary>> = pattern
    {star, chunk, rest}
  end

  defp skip_stars(<<?*, rest::binary>>, _), do: skip_stars(rest, true)
  defp skip_stars(pattern, star), do: {star, pattern}

  defp scan(pattern, index, in_range) when index < byte_size(pattern) do
    case :binary.at(pattern, index) do
      ?\\ ->
        scan(
          pattern,
          if(index + 1 < byte_size(pattern), do: index + 2, else: index + 1),
          in_range
        )

      ?[ ->
        scan(pattern, index + 1, true)

      ?] ->
        scan(pattern, index + 1, false)

      ?* when not in_range ->
        index

      _ ->
        scan(pattern, index + 1, in_range)
    end
  end

  defp scan(_, index, _), do: index

  # Returns {:ok, rest}, :nomatch or {:error, :bad_pattern}. After a failed match
  # the chunk is still checked for syntax, as Go does, without reading name.
  defp match_chunk(chunk, s), do: match_chunk(chunk, s, false)

  defp match_chunk(<<>>, _, true), do: :nomatch
  defp match_chunk(<<>>, s, false), do: {:ok, s}

  defp match_chunk(chunk, s, failed) do
    failed = failed or s == <<>>

    case chunk do
      <<?[, chunk::binary>> ->
        class(chunk, s, failed)

      <<??, chunk::binary>> ->
        if failed do
          match_chunk(chunk, s, true)
        else
          {_, rest} = decode_rune(s)
          match_chunk(chunk, rest, :binary.first(s) == ?/)
        end

      <<?\\>> ->
        {:error, :bad_pattern}

      <<?\\, byte, chunk::binary>> ->
        literal(byte, chunk, s, failed)

      <<byte, chunk::binary>> ->
        literal(byte, chunk, s, failed)
    end
  end

  # A character class consumes one rune of name unless the match already failed.
  defp class(chunk, s, failed) do
    {rune, s} = if failed, do: {0, s}, else: decode_rune(s)

    {negated, chunk} =
      case chunk do
        <<?^, rest::binary>> -> {true, rest}
        _ -> {false, chunk}
      end

    case ranges(chunk, rune, false, 0) do
      {:ok, matched, chunk} -> match_chunk(chunk, s, failed or matched == negated)
      error -> error
    end
  end

  defp literal(_, chunk, s, true), do: match_chunk(chunk, s, true)

  defp literal(byte, chunk, <<first, rest::binary>>, false),
    do: match_chunk(chunk, rest, first != byte)

  defp ranges(<<?], rest::binary>>, _, matched, count) when count > 0, do: {:ok, matched, rest}

  defp ranges(chunk, rune, matched, count) do
    with {:ok, lo, chunk} <- escape(chunk),
         {:ok, hi, chunk} <- range_end(chunk, lo) do
      ranges(chunk, rune, matched or (lo <= rune and rune <= hi), count + 1)
    end
  end

  defp range_end(<<?-, rest::binary>>, _), do: escape(rest)
  defp range_end(chunk, lo), do: {:ok, lo, chunk}

  defp escape(<<>>), do: {:error, :bad_pattern}
  defp escape(<<first, _::binary>>) when first in [?-, ?]], do: {:error, :bad_pattern}
  defp escape(<<?\\>>), do: {:error, :bad_pattern}
  defp escape(<<?\\, rest::binary>>), do: rune(rest)
  defp escape(chunk), do: rune(chunk)

  defp rune(chunk) do
    case decode(chunk) do
      {:invalid, _} -> {:error, :bad_pattern}
      {_, <<>>} -> {:error, :bad_pattern}
      {rune, rest} -> {:ok, rune, rest}
    end
  end

  # utf8.DecodeRuneInString: an invalid byte decodes as U+FFFD, one byte wide.
  defp decode_rune(s) do
    case decode(s) do
      {:invalid, rest} -> {0xFFFD, rest}
      decoded -> decoded
    end
  end

  defp decode(<<rune::utf8, rest::binary>>), do: {rune, rest}
  defp decode(<<_, rest::binary>>), do: {:invalid, rest}
end
