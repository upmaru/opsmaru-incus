defmodule Opsmaru.Incus.NativeYamlReferenceTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.NativeConfig
  @moduletag timeout: 120_000
  @driver Path.expand("../../.integration/incus-yaml-driver", __DIR__)

  # Oracle matrix: Elixir must match native go-yaml v4 + Incus api decoding
  # exactly on every row. Each row was probed against the native driver in
  # test/reference/nativeyaml before being pinned here.
  @oracle_matrix [
    # requested regression rows
    {"ConfigMap", "mode: \"2024-01-01\"", nil},
    {"ConfigMap", "k: '2024-01-01'", nil},
    {"ConfigMap", "mode: \"0755\"", nil},
    {"ConfigMap", "k: '0755'", nil},
    {"ConfigMap", "mode: 0755", nil},
    {"ConfigMap", "n: 1_000", nil},
    {"ConfigMap", "k: 0b101", nil},
    {"ConfigMap", "a: 1\na: 2", nil},
    {"ConfigMap", "x: *nope", nil},
    {"ConfigMap", "b: *v\na: &v hello", nil},
    {"ConfigMap", "k: '*.example.com'", nil},
    {"ConfigMap", "k: *.example.com", nil},
    {"ConfigMap", "k: \" #\"", nil},
    {"ConfigMap", "k: ' #'", nil},
    {"ConfigMap", "k: \"null\"\nj: null", nil},
    {"ConfigMap", "k: |\n  2024-01-01T00:00:00Z", nil},
    {"DevicesMap", "dm:\n  <<: {n: 1}\n  n: 2", nil},
    # merge keys
    {"ConfigMap", "<<: {a: 1}\nb: 2", nil},
    {"ConfigMap", "<<: &m {a: 1, c: 2}\nb: 2", nil},
    {"ConfigMap", "<<: [{a: 1}, {a: 9, b: 3}]\nc: 4", nil},
    {"ConfigMap", "<<: *x\nx: {a: 1}", nil},
    {"ConfigMap", "<<: [{a: 1}, {a: 9}]\na: 7", nil},
    {"ConfigMap", "<<: [!m {a: 1}, {a: 9}]\nc: 3", nil},
    {"ConfigMap", "<<: 5", nil},
    {"ConfigMap", "<<: [{a: 1}, 2]", nil},
    {"ConfigMap", "<<: &m {a: 1}\n<<: *m\nb: 3", nil},
    {"DevicesMap", "net0:\n  name: eth0", nil},
    {"DevicesMap", "net0:\n  name: 1", nil},
    {"DevicesMap", "net0:\n  <<: &base {a: 1, b: 2}\n  b: 3\n  c: 4", nil},
    # merge-from-anchored-template (common real-world form)
    {"DevicesMap", "d0: &d0 {k: v}\nd1: {<<: *d0}\n", nil},
    {"DevicesMap", "d0: &d0 {k: v}\nd1: {<<: [*d0]}\n", nil},
    {"DevicesMap", "d0: &d0 {k: v}\nd1: {<<: [*d0, *d0]}\n", nil},
    {"DevicesMap", "d0: &d0 {k: v}\nx: &x {j: w}\nd1: {<<: [*d0, *x]}\n", nil},
    {"DevicesMap", "d0: &d0 {k: v}\nd1: &d1 {<<: *d0}\nd2: {<<: *d1}\n", nil},
    {"DevicesMap", "d0: &d0\n  k: v\nd1:\n  <<: *d0\n  extra: 1\n", nil},
    {"DevicesMap", "d0: &d0 {k: v}\nd1: *d0\n", nil},
    {"DevicesMap", "d0: &d0 {k: v}\nd1: &d1 {<<: [*d0, *d0]}\nd2: {<<: [*d1, *d1]}\n", nil},
    {"ConfigMap", "m: &m {a: 1}\n<<: *m\nb: 2", nil},
    {"ConfigMap", "m: &m {a: 1}\n<<: [*m]\nc: 2", nil},
    # explicit tags
    {"ConfigMap", "k: !!int 1.5", nil},
    {"ConfigMap", "k: !!float 0x10", nil},
    {"ConfigMap", "k: !!str 1", nil},
    {"ConfigMap", "k: !!str 0755", nil},
    {"ConfigMap", "k: !!str .5_5", nil},
    {"ConfigMap", "k: !!str <<", nil},
    {"ConfigMap", "k: !!binary aGk=", nil},
    {"ConfigMap", "k: !!bool yes", nil},
    {"ConfigMap", "k: !!bool FALSE", nil},
    {"ConfigMap", "k: !!null x", nil},
    {"ConfigMap", "k: !!null null", nil},
    {"ConfigMap", "k: !!int -0", nil},
    {"ConfigMap", "k: !!int -0.0", nil},
    {"ConfigMap", "k: !!int true", nil},
    {"ConfigMap", "k: !!int 1e3", nil},
    {"ConfigMap", "k: !!int 1.0", nil},
    {"ConfigMap", "k: !!int 1_0", nil},
    {"ConfigMap", "k: !!int 18446744073709551615", nil},
    {"ConfigMap", "k: !!float -0", nil},
    {"ConfigMap", "k: !!float true", nil},
    {"ConfigMap", "k: !!float 1_0.5", nil},
    {"ConfigMap", "k: !!float _1.5", nil},
    {"ConfigMap", "k: !!float .5_5", nil},
    {"ConfigMap", "k: !!float .nan", nil},
    {"ConfigMap", "k: !!float 1e309", nil},
    {"ConfigMap", "k: !!float 1.0", nil},
    {"ConfigMap", "k: !!timestamp 2024-01-01", nil},
    {"ConfigMap", "k: !!timestamp 123", nil},
    {"ConfigMap", "k: !custom 5", nil},
    # merge tag semantics
    {"ConfigMap", "k: !!merge x", nil},
    {"ConfigMap", "b: 1\na: !!merge x", nil},
    {"ConfigMap", "a: !!merge <<", nil},
    {"ConfigMap", "<<: !!merge x", nil},
    {"ConfigMap", "!!merge k: 1", nil},
    {"ConfigMap", "!!merge <<: {a: 1}\nb: 2", nil},
    # nulls, documents, directives
    {"ConfigMap", "k: null\nj: 1", nil},
    {"ConfigMap", "k: NULL", nil},
    {"ConfigMap", "k: ~", nil},
    {"ConfigMap", "k: \"\"", nil},
    {"ConfigMap", "", nil},
    {"ConfigMap", "---", nil},
    {"ConfigMap", "null", nil},
    {"DevicesMap", "---\nnet0:\n  name: e", nil},
    {"ConfigMap", "a: 1\n---\nb: 2", nil},
    {"ConfigMap", "---\na: 1\n---\nb: 2\n", nil},
    {"ConfigMap", "%YAML 1.1\n---\na: 1", nil},
    {"ConfigMap", "%YAML 1.2\n---\na: 1", nil},
    {"ConfigMap", "%YAML 1.0\n---\na: 1", nil},
    {"ConfigMap", "%YAML 2.0\n---\na: 1", nil},
    {"ConfigMap", "%X reserved\n---\na: 1", nil},
    {"ConfigMap", "%TAG !x! tag:x:\n---\n!x!foo a: 1", nil},
    # existing merges
    {"ConfigMap", "b: 2", %{"a" => "1", "b" => "old"}},
    {"ConfigMap", "---", %{"a" => "1"}},
    {"ConfigMap", "", %{"a" => "1"}},
    {"DevicesMap", "net0:\n  b: 2", %{"net0" => %{"a" => "1"}}},
    {"DevicesMap", "", %{"net0" => %{"a" => "1"}}},
    {"DevicesMap", "---", %{"net0" => %{"a" => "1"}}},
    # resolution: numbers, floats, underscores
    {"ConfigMap", "k: @x", nil},
    {"ConfigMap", "k: `x", nil},
    {"ConfigMap", "k: 1e309", nil},
    {"ConfigMap", "k: 1.5e2", nil},
    {"ConfigMap", "k: 1e-05", nil},
    {"ConfigMap", "k: 0.0001", nil},
    {"ConfigMap", "k: 123456789.123456789", nil},
    {"ConfigMap", "k: -0.0", nil},
    {"ConfigMap", "k: .nan", nil},
    {"ConfigMap", "k: .inf", nil},
    {"ConfigMap", "k: -.inf", nil},
    {"ConfigMap", "k: True", nil},
    {"ConfigMap", "k: false", nil},
    {"ConfigMap", "k: +5", nil},
    {"ConfigMap", "k: 010", nil},
    {"ConfigMap", "k: 08", nil},
    {"ConfigMap", "k: 1__0", nil},
    {"ConfigMap", "k: _1", nil},
    {"ConfigMap", "k: 1._5", nil},
    {"ConfigMap", "k: 1_0", nil},
    {"ConfigMap", "k: 1_0.5", nil},
    {"ConfigMap", "k: 1.5_5", nil},
    {"ConfigMap", "k: 1e1_0", nil},
    {"ConfigMap", "k: _1.5", nil},
    {"ConfigMap", "k: 1.5_", nil},
    {"ConfigMap", "k: _.5", nil},
    {"ConfigMap", "k: 0x_1", nil},
    {"ConfigMap", "k: -.5", nil},
    {"ConfigMap", "k: -_.5", nil},
    {"ConfigMap", "k: .5", nil},
    {"ConfigMap", "k: .5_5", nil},
    {"ConfigMap", "k: .5_.5", nil},
    {"ConfigMap", "k: .", nil},
    {"ConfigMap", "k: 18446744073709551615", nil},
    {"ConfigMap", "k: 18446744073709551616", nil},
    {"ConfigMap", "k: -9223372036854775808", nil},
    {"ConfigMap", "k: -9223372036854775809", nil},
    {"ConfigMap", "k: 0x1p3", nil},
    # timestamps
    {"ConfigMap", "k: 2024-01-01", nil},
    {"ConfigMap", "k: 2024-02-30", nil},
    {"ConfigMap", "k: 2024-13-01", nil},
    {"ConfigMap", "k: 2024-01-01T24:00:00Z", nil},
    {"ConfigMap", "k: 2024-01-01 10:00:00", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:00+24:00", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:00+24:59", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:00+24:60", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:00+99:00", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:00+23:59", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:00-24:00", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:00+2:00", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:00.5Z", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:00.12345678901Z", nil},
    {"ConfigMap", "k: 2024-01-01T10:5:3Z", nil},
    {"ConfigMap", "k: 2024-01-01T10:5:3", nil},
    {"ConfigMap", "k: 2024-1-2", nil},
    {"ConfigMap", "k: 2024-01-1", nil},
    {"ConfigMap", "k: 99999-01-01", nil},
    {"ConfigMap", "k: 2024-01-01T10:00:60Z", nil},
    {"ConfigMap", "k: 2024-02-29", nil},
    {"ConfigMap", "k: 2023-02-29", nil},
    {"ConfigMap", "k: 1999-02-29", nil},
    # anchors / aliases
    {"ConfigMap", "a: &v hello\nb: *v", nil},
    {"ConfigMap", "a: &v 1\nb: &v 2\nc: *v", nil},
    {"ConfigMap", "a: &v {x: 1}\nb: *v", nil},
    {"ConfigMap", "a: &self [*self]\nb: 1", nil},
    # null / dropped keys
    {"ConfigMap", "0755: 1", nil},
    {"ConfigMap", "true: 1", nil},
    {"ConfigMap", "false: 1", nil},
    {"ConfigMap", "1.5: 1", nil},
    {"ConfigMap", "~: 1", nil},
    {"ConfigMap", "~: 1\nb: 2", nil},
    {"ConfigMap", "null: 1", nil},
    {"ConfigMap", "0x10: 1", nil},
    {"ConfigMap", ".inf: 1", nil},
    {"ConfigMap", "<< x: 1", nil},
    {"ConfigMap", "!!str 5: 1", nil},
    {"ConfigMap", ".nan: 1\nb: 2", nil},
    {"ConfigMap", "a: 1\n~: 2", nil},
    {"ConfigMap", "0: 1", nil},
    {"ConfigMap", "{a: 1}: 2", nil},
    {"ConfigMap", "- 1: 2", nil},
    {"ConfigMap", "08: x\n1e3: y\n0755: z", nil},
    {"DevicesMap", "1: {a: 1}", nil},
    # unsupported shapes and syntax errors
    {"ConfigMap", "k: [1, 2]", nil},
    {"ConfigMap", "k: {nested: {deep: 1}}", nil},
    {"ConfigMap", "- 1\n- 2", nil},
    {"ConfigMap", "k: 1\nextra: 2\ngarbage after doc", nil},
    {"ConfigMap", "a: [1, 2,}", nil},
    {"ConfigMap", "a: \"unterminated", nil}
  ]

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./nativeyaml"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  for type <- ["ConfigMap", "DevicesMap"] do
    test "#{type} plain, quoted and structural scalars match native go-yaml v4", %{} do
      type = unquote(type)

      for body <- [
            "k: v",
            "k: 'quoted'",
            "k: \"doubles\"",
            "k: 'a # b'",
            "k: a # trailing",
            "k: ''",
            "k: yes\nl: no\nm: on",
            "k: true\nl: False\nm: FALSE",
            "k: null\nl: ~\nm: NULL",
            "k: 雪\nl: native+/é",
            "k: 123abc\nl: 1.2.3",
            "k: |-\n  line",
            "k: >\n  fold\n  me",
            "k: |\n  l1\n  l2",
            "k: >-\n  fold\n  me",
            "k: multi\n  line",
            "v: &v n\na: *v\nb: *v"
          ] do
        yaml = device_yaml(type, body)
        assert_matches(type, yaml, nil, oracle(type, yaml, nil))
      end
    end

    test "#{type} null documents, absent documents and existing merges match native", %{} do
      type = unquote(type)
      existing = if type == "ConfigMap", do: %{"kept" => "k"}, else: %{"dev" => %{"kept" => "k"}}

      for {yaml, note} <- [
            {"", "absent document leaves existing untouched"},
            {"# only a comment", "comment-only input leaves existing untouched"},
            {"null", "null document resets the target to nil"},
            {"~", "tilde document resets the target to nil"},
            {"---", "bare document marker resets the target to nil"},
            {"k: 1", "update merges into existing"},
            {if(type == "ConfigMap", do: "k: null", else: "dev:\n  k: null"),
             "null value becomes the empty string"}
          ] do
        _ = note
        result = oracle(type, yaml, existing)
        assert_matches(type, yaml, existing, result)
      end

      # A null document resets even when existing is populated, and an absent
      # document leaves it untouched.
      assert {:ok, nil} = NativeConfig.from_yaml(type, "null", existing)
      assert {:ok, ^existing} = NativeConfig.from_yaml(type, "", existing)
    end

    test "#{type} rejects unsupported shapes exactly like the native decoder", %{} do
      type = unquote(type)

      bad =
        if type == "ConfigMap",
          do: [
            "k: [1, 2]",
            "k:\n  nested: x",
            "- a",
            "just a string"
          ],
          else: [
            "dev: null",
            "dev: x",
            "dev:\n  k: [1]",
            "dev:\n  1: x",
            "- a"
          ]

      for yaml <- bad do
        result = oracle(type, yaml, nil)

        assert result["accepted"] == false,
               "#{inspect(yaml)} unexpectedly accepted: #{inspect(result)}"

        assert {:error, %Error{kind: :invalid_native_config}} = NativeConfig.from_yaml(type, yaml)
      end
    end
  end

  test "integer bases, uint64 range and float64 fallback match native resolution" do
    for body <- [
          "k: 0\nl: -1\nm: 42",
          "k: +42\nl: 08\nm: 9223372036854775806",
          "k: 9223372036854775807\nl: -9223372036854775808",
          "k: 9223372036854775808\nl: 18446744073709551615",
          "k: 18446744073709551616\nl: -9223372036854775809",
          "k: 99999999999999999999999999",
          "k: 0x1a\nl: -0x10\nm: 0o17",
          "k: 7.0\nl: -2.75\nm: 0.00001",
          "k: .5\nl: 1e3\nm: 2.5e2",
          "k: 1.5e-3\nl: 1.0e20\nm: 1.7976931348623157e308",
          "k: .inf\nl: -.inf\nm: .nan",
          "k: -0\nl: -0.0",
          "k: 9223372036854775808.0"
        ] do
      for {type, yaml} <- [
            {"ConfigMap", body},
            {"DevicesMap", "dev:\n  " <> String.replace(body, "\n", "\n  ")}
          ] do
        result = oracle(type, yaml, nil)
        assert_matches(type, yaml, nil, result)
      end
    end
  end

  test "scalar outer keys, first-document selection and device merges match native" do
    for {type, yaml, existing} <- [
          {"ConfigMap", "1: x\n2: y", nil},
          {"ConfigMap", "1.5: x", nil},
          {"ConfigMap", "true: x", nil},
          {"ConfigMap", "k: 1\n---\nl: 2", nil},
          {"ConfigMap", "k: 1\nl: 2", %{"k" => "old", "kept" => "k"}},
          {"DevicesMap", "dev:\n  k: v\nother:\n  a: b", nil},
          {"DevicesMap", "dev:\n  k: 7\n  b: true", %{"dev" => %{"kept" => "k"}}}
        ] do
      result = oracle(type, yaml, existing)
      assert_matches(type, yaml, existing, result)
    end
  end

  test "oracle matrix matches native go-yaml v4 on every case" do
    entries =
      for {type, yaml, existing} <- @oracle_matrix do
        entry = %{"type" => type, "yaml" => yaml}
        if(existing, do: Map.put(entry, "existing", existing), else: entry)
      end

    results = oracle_many(entries)

    for {row, result} <- Enum.zip(Enum.zip(entries, @oracle_matrix), results),
        {_entry, {type, yaml, existing}} = row do
      assert_matches(type, yaml, existing, result)
    end
  end

  # --- Documented yamerl vs go-yaml v4 divergences -------------------------
  # Each test pins both sides: the native oracle result and the Elixir result.
  # These remain divergences because yamerl, the fixed scanner/lexer
  # dependency, accepts or rejects the input differently from libyaml.

  test "divergence: tab indentation is rejected natively, accepted by yamerl" do
    yaml = "k:\n\tl: x"
    result = oracle("ConfigMap", yaml, nil)
    assert result["accepted"] == false
    assert {:ok, %{"k" => "", "l" => "x"}} = NativeConfig.from_yaml("ConfigMap", yaml)
  end

  test "divergence: non-UTF8 !!binary is accepted natively with U+FFFD replacement" do
    result = oracle("ConfigMap", "k: !!binary gYG=", nil)
    assert result["accepted"] == true

    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("ConfigMap", "k: !!binary gYG=")

    # Valid UTF-8 binary content matches on both sides.
    result = oracle("ConfigMap", "k: !!binary aGk=", nil)
    assert result["value"] == %{"k" => "hi"}
    assert {:ok, %{"k" => "hi"}} = NativeConfig.from_yaml("ConfigMap", "k: !!binary aGk=")
  end

  test "divergence: the native aliasing-ratio check is stricter than our expansion budget" do
    # Six tail aliases expand to about 947k nodes, just under our 1M-node
    # budget, so the parser accepts the input. go-yaml v4 rejects the same
    # input with its alias/construct ratio check, which fires for any
    # substantial expansion. The bound is demonstrated by the bomb test
    # above, where the just-under variant is accepted on the parser side
    # only.
    just_under = merge_bomb(6)
    result = oracle("DevicesMap", just_under, nil)
    assert result["accepted"] == false

    assert {:ok, value} = NativeConfig.from_yaml("DevicesMap", just_under)
    assert value["d6"] == %{"k" => "v"}
  end

  # --- Safety ---------------------------------------------------------------

  test "oversized input and invalid types fail without exposing config" do
    for {type, yaml, existing} <- [
          {"ConfigMap", String.duplicate("k: v\n", 210_000), nil},
          {"unknown", "k: v", nil},
          {"ConfigMap", 42, nil},
          {"ConfigMap", "k: private-value", %{"private" => 7}},
          {"DevicesMap", "k: v", %{"dev" => []}}
        ] do
      assert {:error, %Error{kind: :invalid_native_config} = error} =
               NativeConfig.from_yaml(type, yaml, existing)

      refute inspect(error) =~ "private"
    end
  end

  # dN: &dN {<<: [*d(N-1) x9]} for N=1..6: every alias re-expands the whole
  # anchored subtree, so the cost grows as 9**(N-1): about 149k cumulative
  # through d5, and d6 alone expands to 9 x 132,860 nodes. The last level
  # carries tail_aliases aliases: 6 land at about 947k nodes (just under
  # the 1M-node budget), 7 at about 1.08M (just over).
  defp merge_bomb(tail_aliases) do
    lines =
      Enum.map(1..6, fn n ->
        count = if n == 6, do: tail_aliases, else: 9
        alias = Enum.join(List.duplicate("*d" <> Integer.to_string(n - 1), count), ", ")
        "d#{n}: &d#{n} {<<: [#{alias}]}"
      end)

    Enum.join(["d0: &d0 {k: v}" | lines], "\n") <> "\n"
  end

  test "alias bombs are rejected by the expansion budget within the reference bound" do
    # (a) Small fan-out is accepted and equals native.
    small =
      "d0: &d0 {k: v}\n" <>
        "d1: &d1 {<<: [*d0, *d0]}\n" <>
        "d2: {<<: [*d1, *d1]}\n"

    assert_matches("DevicesMap", small, nil, oracle("DevicesMap", small, nil))

    # (b) Full 9-alias fan-out: native rejects it for excessive aliasing and
    # ours rejects it on the expansion budget, fast and without
    # materializing the fan-out.
    bomb = merge_bomb(9)
    assert_matches("DevicesMap", bomb, nil, oracle("DevicesMap", bomb, nil))

    memory_before = :erlang.process_info(self(), :memory)
    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("DevicesMap", bomb)

    elapsed = System.monotonic_time(:millisecond) - started
    memory_after = :erlang.process_info(self(), :memory)

    assert elapsed < 2000, "bomb took #{elapsed}ms"

    assert elem(memory_after, 1) - elem(memory_before, 1) < 1_000_000

    # (c) Six tail aliases charge about 947k expanded nodes, just under
    # the 1M-node budget, so the rejection in (b) comes from the budget,
    # not a shape error. The native driver has no verdict to compare
    # against: its own aliasing-ratio check (named divergence below)
    # rejects this input too, strictly stricter than our bound.
    assert {:ok, value} = NativeConfig.from_yaml("DevicesMap", merge_bomb(6))
    assert value["d6"] == %{"k" => "v"}

    # Seven tail aliases cross the budget at about 1.08M nodes.
    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("DevicesMap", merge_bomb(7))
  end

  test "unique input keys create no atoms and parsing never raises" do
    for index <- 1..200 do
      key = "key-#{index}-unique-#{:erlang.phash2(index)}"
      value = "value-#{index}"
      yaml = "#{key}: #{value}"

      assert {:ok, %{^key => ^value}} = NativeConfig.from_yaml("ConfigMap", yaml)
      refute atom_exists?(key), "input key became an atom"
    end

    for garbage <- [
          <<0, 0, 0>>,
          "k: [",
          "k:\n- a\n- b\nc: d",
          String.duplicate("k: v\n", 5000),
          "!!binary not-base64"
        ] do
      case NativeConfig.from_yaml("ConfigMap", garbage) do
        {:ok, _} -> :ok
        {:error, %Error{}} -> :ok
        other -> flunk("unexpected result for #{inspect(garbage)}: #{inspect(other)}")
      end
    end
  end

  test "errors redact payloads and leave the yamerl application env untouched" do
    env_before = :application.get_all_env(:yamerl)
    secret = "secret-" <> Integer.to_string(:erlang.phash2(System.unique_integer()))

    assert {:error, %Error{kind: :invalid_native_config} = error} =
             NativeConfig.from_yaml("ConfigMap", "k: #{secret}\nl: [1]", nil)

    refute inspect(error) =~ secret
    assert :application.get_all_env(:yamerl) == env_before
  end

  # Precise "does this atom already exist" check that creates nothing.
  defp atom_exists?(binary) do
    _ = String.to_existing_atom(binary)
    true
  rescue
    ArgumentError -> false
  end

  defp assert_matches(type, yaml, existing, result) do
    got = NativeConfig.from_yaml(type, yaml, existing)

    case result["accepted"] do
      true ->
        assert {:ok, value} = got,
               "expected #{inspect(yaml)} to be accepted, got #{inspect(got)}"

        assert value == result["value"],
               "native mismatch for #{type} #{inspect(yaml)}: #{inspect(value)} != #{inspect(result["value"])}"

      false ->
        assert {:error, %Error{kind: :invalid_native_config}} = got,
               "expected #{inspect(yaml)} to be rejected, got #{inspect(got)}"
    end
  end

  defp device_yaml("ConfigMap", body), do: body

  defp device_yaml("DevicesMap", body) do
    "dev:\n  " <> String.replace(body, "\n", "\n  ")
  end

  defp oracle(type, yaml, existing) do
    case = %{"type" => type, "yaml" => yaml}
    case = if(existing, do: Map.put(case, "existing", existing), else: case)
    hd(oracle_many([case]))
  end

  defp oracle_many(cases) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{cases: cases}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} when byte_size(data) + byte_size(bytes) <= 1_048_576 ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)["results"]

      {^port, {:exit_status, status}} ->
        flunk("native yaml oracle failed #{status}: #{data}")
    after
      10_000 ->
        Port.close(port)
        flunk("native yaml oracle deadline")
    end
  end
end
