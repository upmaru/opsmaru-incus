defmodule Opsmaru.Incus.NativeYamlFixtures do
  # Nested flow mapping/sequence of the given depth, placed under a dropped
  # key so deep flows (which the Incus shapes otherwise reject) can be
  # probed at the scanner nesting boundary.
  def deep_flow(depth) do
    nest = Enum.reduce(depth..1, "x", fn i, acc -> "{a#{i}: #{acc}}" end)
    "~:\n  k: " <> nest <> "\n"
  end

  def deep_seq(depth) do
    nest = String.duplicate("[", depth) <> "x" <> String.duplicate("]", depth)
    "~:\n  k: " <> nest <> "\n"
  end

  def devices_deep_flow(depth) do
    nest = Enum.reduce(depth..1, "x", fn i, acc -> "{a#{i}: #{acc}}" end)
    "~:\n  d: " <> nest <> "\n"
  end

  # A nested literal merge chain of the given depth: `depth` flow mappings,
  # each carrying one entry and merging the next, ending in {z: x}.
  # Placed under a device key so the chain is a valid DevicesMap shape.
  def merge_chain(depth) do
    nest = Enum.reduce(depth..1//-1, "{z: x}", fn i, acc -> "{a#{i}: x, <<: #{acc}}" end)
    "d: " <> nest <> "\n"
  end
end

defmodule Opsmaru.Incus.NativeYamlReferenceTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.NativeConfig
  alias Opsmaru.Incus.NativeYamlFixtures
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
    # anchored values under dropped keys stay aliasable
    {"ConfigMap", "~: &m {a: 1}\n<<: *m\n", nil},
    {"ConfigMap", "~: &m {a: 1}\nb: *m\n", nil},
    {"ConfigMap", "~: {a: 1, a: 2}\nb: 3\n", nil},
    {"ConfigMap", "~: &m {a: 1}\nb: 3\n<<: *m\n", nil},
    {"ConfigMap", "~: [1, 2]\nb: 3\n", nil},
    {"ConfigMap", "~: &s [1, 2]\nb: 3\n", nil},
    {"ConfigMap", "~: &s [1, 2]\n<<: [*s]\n", nil},
    {"ConfigMap", "~: &s [{a: 1}]\n<<: [*s]\n", nil},
    {"ConfigMap", "~: &s [{a: 1}]\n<<: *s\n", nil},
    {"ConfigMap", "~: &s [{a: 1}, 2]\n<<: [*s]\n", nil},
    {"ConfigMap", "~: &s [{a: 1}, {b: 2}]\n<<: [*s]\n", nil},
    {"ConfigMap", "~: &s [1, 2]\n<<: [*s, *s]\n", nil},
    {"ConfigMap", "~: &m {a: 1}\n<<: *m\n<<: *m\n", nil},
    # merge sources must not leak their construction context
    {"DevicesMap", "d0: {<<: {k: v}}\nd1: {1: x}\n", nil},
    {"DevicesMap", "d0: {<<: *x}\nd1: {k: v}\nx: &x {j: w}\n", nil},
    # dot-leading and dot-trailing floats at end of input
    {"ConfigMap", "k: .5e2\n", nil},
    {"ConfigMap", "k: !!float .5e2\n", nil},
    {"ConfigMap", "k: .5e-2\n", nil},
    {"ConfigMap", "k: -.5E+2\n", nil},
    {"ConfigMap", "k: .5e\n", nil},
    {"ConfigMap", "k: 5e2\n", nil},
    {"ConfigMap", "k: !!float 5e2\n", nil},
    {"ConfigMap", "k: !!float 1e\n", nil},
    {"ConfigMap", "k: 1.e2\n", nil},
    {"ConfigMap", "k: -1.e2\n", nil},
    {"ConfigMap", "k: +.5e2\n", nil},
    {"ConfigMap", "k: !!float 1.e2\n", nil},
    {"ConfigMap", "k: !!float -.5e2\n", nil},
    {"ConfigMap", "k: 1.e\n", nil},
    {"ConfigMap", "k: 1.\n", nil},
    {"ConfigMap", "k: 0.\n", nil},
    {"ConfigMap", "k: 1.5e\n", nil},
    {"ConfigMap", "k: .5_0e2\n", nil},
    {"ConfigMap", "k: .5_0\n", nil},
    {"ConfigMap", "k: 1.5_0\n", nil},
    # failed tag resolution under dropped keys is lazy: only an error when
    # the value or key is actually constructed (aliased or merged in use)
    {"ConfigMap", "~: [5e2]\nnull: {x: !!float ~}\n", nil},
    {"ConfigMap", "~: &m1 {a1: !!float null, b: .5e-2}\nk2: !!float 0\n", nil},
    {"ConfigMap", "k1: -.5\n~: &s2 ['null', !!float true]\n", nil},
    {"DevicesMap", "~: &d1 {k: !!float 2024-01-01}\nd2: {<<: [*d1, {z: 1}], k: x}\n", nil},
    {"ConfigMap", "~: &m {k: !!float abc}\nb: *m\n", nil},
    {"ConfigMap", "~: &m {k: !!float abc}\n<<: *m\n", nil},
    {"ConfigMap", "~: &m {k: !!float abc}\n<<: *m\nk: v\n", nil},
    {"ConfigMap", "~: {a: [1]}\nb: 2\n", nil},
    {"ConfigMap", "~: &m {a: {b: !!float abc}}\n<<: *m\n", nil},
    {"ConfigMap", "~: &s [!!float abc]\nb: 2\n", nil},
    {"ConfigMap", "k: !!float abc\n", nil},
    # failed tag resolution on keys is lazy the same way
    {"ConfigMap", "~: {!!int abc: 1}\nb: 2\n", nil},
    {"ConfigMap", "~: &m {!!int abc: 1}\n<<: *m\n", nil},
    {"ConfigMap", "~: &m {!!int abc: 1}\nk: v\n<<: *m\n", nil},
    # inline merge-source values are lazy too when overridden
    {"DevicesMap", "d: {<<: [{k: !!float abc}], k: x}\n", nil},
    # aliased dropped maps run the same key checks native applies at
    # construction: key type, raw-text duplicates, and null-key handling
    {"DevicesMap", "~: &m {1: x}\nd: *m\n", nil},
    {"DevicesMap", "~: &m {\"1\": x, 1: y}\nd: *m\n", nil},
    {"DevicesMap", "~: &m {a: 1, a: 2}\nd: *m\n", nil},
    {"DevicesMap", "~: &m {~: x}\nd: *m\n", nil},
    {"DevicesMap", "~: &m {2024-01-01: x}\nd: *m\n", nil},
    {"DevicesMap", "~: &m {true: x}\nd: *m\n", nil},
    {"DevicesMap", "~: &m {k: v}\nn: &n {d: *m}\nd: *n\n", nil},
    {"DevicesMap", "~: &m {a: 1, a: 2}\nd: {<<: *m, b: z}\n", nil},
    {"DevicesMap", "d: &m {a: 1, a: 2}\ne: *m\n", nil},
    {"ConfigMap", "~: &m {a: 1, a: 2}\n<<: *m\n", nil},
    {"ConfigMap", "~: &m {a: 1, a: 2}\n<<: *m\na: x\n", nil},
    {"ConfigMap", "~: &m {\"1\": x, 1: y}\n<<: *m\n", nil},
    {"ConfigMap", "~: &m {1: x, 0x1: y}\n<<: *m\n", nil},
    {"ConfigMap", "{1: x, 0x1: y}\n", nil},
    {"ConfigMap", "~: &m {1.5: x, 1.50: y}\n<<: *m\n", nil},
    {"ConfigMap", "~: &m {~: x, ~: y}\n<<: *m\n", nil},
    {"ConfigMap", "~: &m {~: x, null: y}\n<<: *m\n", nil},
    {"ConfigMap", "~: &m {\"\": x, ~: y}\n<<: *m\n", nil},
    {"ConfigMap", "\"\": x\n", nil},
    # timestamp keys fail string-key construction everywhere
    {"ConfigMap", "2024-01-01: x\n", nil},
    {"ConfigMap", "~: &m {2024-01-01: x}\n<<: *m\n", nil},
    {"DevicesMap", "2024-01-01: {k: v}\n", nil},
    # merge-tagged values drop their entry; the key still counts for dups
    {"ConfigMap", "k: !!merge x\n", nil},
    {"ConfigMap", "a: !!merge <<\n", nil},
    {"ConfigMap", "k: !!merge x\nk: 1\n", nil},
    {"ConfigMap", "~: &m {k: !!merge x}\n<<: *m\n", nil},
    {"DevicesMap", "d: {.inf: !!merge x}\n", nil},
    # non-finite float keys keep their raw text into map[string]any
    {"ConfigMap", ".inf: 1\n", nil},
    {"ConfigMap", ".nan: 1\nb: 2\n", nil},
    {"ConfigMap", "~: &m {.inf: 1}\n<<: *m\n", nil},
    {"DevicesMap", "d: {.nan: x}\n", nil},
    # literal merge sources compose at any nesting depth
    {"ConfigMap", "~: &m {<<: {a: 1}}\n<<: *m\n", nil},
    {"ConfigMap", "~: &m {<<: {a: 1}, a: 2}\n<<: *m\n", nil},
    {"DevicesMap", "~: &m {<<: [{a: 1}, {b: 2}]}\nd: {<<: *m}\n", nil},
    # underscore handling mirrors Go strconv.ParseFloat exactly
    {"ConfigMap", "k: _5\n", nil},
    {"ConfigMap", "k: ._5\n", nil},
    {"ConfigMap", "k: 5_\n", nil},
    {"ConfigMap", "k: 5__0\n", nil},
    {"ConfigMap", "k: 0x_1\n", nil},
    {"ConfigMap", "k: 0_x1\n", nil},
    {"ConfigMap", "k: 1e_5\n", nil},
    {"ConfigMap", "k: 1_e5\n", nil},
    {"ConfigMap", "k: .5_\n", nil},
    {"ConfigMap", "k: -_5\n", nil},
    {"ConfigMap", "k: +_.5\n", nil},
    {"ConfigMap", "k: !!float _5\n", nil},
    {"ConfigMap", "k: !!float ._5\n", nil},
    {"ConfigMap", "k: !!float 5_\n", nil},
    {"ConfigMap", "k: !!float 5__0\n", nil},
    {"ConfigMap", "k: !!float 0x_1\n", nil},
    {"ConfigMap", "k: !!float 0_x1\n", nil},
    {"ConfigMap", "k: !!float 1e_5\n", nil},
    {"ConfigMap", "k: !!float 1_e5\n", nil},
    {"ConfigMap", "k: !!float .5_\n", nil},
    {"ConfigMap", "k: !!float -_5\n", nil},
    {"ConfigMap", "k: !!float +_.5\n", nil},
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
    {"ConfigMap", "a: \"unterminated", nil},
    # first-document selection: syntax beyond the two-token lookahead window
    {"ConfigMap", "a: 1\n---\nb: [unterminated\n", nil},
    {"ConfigMap", "a: 1\n---\nb: [\n", nil},
    {"ConfigMap", "a: 1\n...\nb: [\n", nil},
    {"ConfigMap", "a: 1\n---\n[\n", nil},
    {"ConfigMap", "a: 1\n---\n{\n", nil},
    {"ConfigMap", "---\na: 1\n---\nb: [\n", nil},
    {"ConfigMap", "a: 1\n...\n...\n", nil},
    {"ConfigMap", "a: 1\n---\n...\n", nil},
    {"ConfigMap", "a: 1\n...\nb: 1\n---\nc: [\n", nil},
    {"ConfigMap", "a: 1\n---\nc: 1\n... \nbad: [\n", nil},
    {"ConfigMap", "a: 1\n---\n%YAML 1.1\nb: [\n", nil},
    {"ConfigMap", "a: 1\n---\n# comment\nb: [\n", nil},
    {"ConfigMap", "a: 1\n...\n# c\nb: [\n", nil},
    {"ConfigMap", "a: 1\n---\n- 1\n", nil},
    {"ConfigMap", "a: 1\n---\nk: v\n", nil},
    {"ConfigMap", "a: 1\n---\nb: &x [1, 2]\n", nil},
    {"DevicesMap", "d1: {a: 1}\n---\nd2: [bad\n", nil},
    {"ConfigMap", "a: 1\n---\n\"unterminated\n", nil},
    {"ConfigMap", "a: 1\n---\n'bad\n", nil},
    # nesting beyond the native 10_000-level scanner limit (dropped values,
    # which are the only place deep flows can be accepted at all)
    {"ConfigMap", NativeYamlFixtures.deep_flow(50), nil},
    {"ConfigMap", NativeYamlFixtures.deep_flow(1_000), nil},
    {"ConfigMap", NativeYamlFixtures.deep_flow(10_001), nil},
    {"ConfigMap", NativeYamlFixtures.deep_seq(1_000), nil},
    {"ConfigMap", NativeYamlFixtures.deep_seq(10_001), nil},
    {"DevicesMap", NativeYamlFixtures.devices_deep_flow(10_001), nil},
    # nested literal merge chains within the flow nesting work bound
    {"DevicesMap", NativeYamlFixtures.merge_chain(100), nil},
    {"DevicesMap", NativeYamlFixtures.merge_chain(400), nil}
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
    # Four tail aliases charge about 983k expanded nodes, just under our
    # 1M-node budget, so the parser accepts the input. go-yaml v4 rejects
    # the same input with its alias/construct ratio check, which fires for
    # any substantial alias fan-out (even the single-alias variant of the
    # 9-fan-out bomb). The bound is demonstrated by the bomb test above,
    # where the just-under variant is accepted on the parser side only.
    just_under = merge_bomb(4)
    result = oracle("DevicesMap", just_under, nil)
    assert result["accepted"] == false

    assert {:ok, value} = NativeConfig.from_yaml("DevicesMap", just_under)
    assert value["d6"] == %{"k" => "v"}
  end

  test "divergence: native accepts flow nesting to 10_000 levels; ours bounds total nesting work" do
    # A depth-10_000 nested flow mapping fits the native 10_000-level
    # scanner limit, so the native oracle accepts it. Its flow nesting
    # work (about 10^8 depth-units) exceeds the 10_000_000 bound in
    # Opsmaru.Incus.NativeConfig (@max_flow_work): yamerl's scan of such a
    # document takes seconds (its implicit-key index is walked once per
    # token), so ours rejects it before scanning to keep worst-case
    # decoding inside the reference bound. The depth-1_000 variant stays
    # under the bound and matches native (matrix row).
    for yaml <- [NativeYamlFixtures.deep_flow(10_000), NativeYamlFixtures.deep_seq(10_000)] do
      result = oracle("ConfigMap", yaml, nil)
      assert result["accepted"] == true

      assert {:error, %Error{kind: :invalid_native_config}} =
               NativeConfig.from_yaml("ConfigMap", yaml)
    end

    # The nested merge chain shape from the native decoder's perspective:
    # a single depth-9999 chain is accepted natively but rejected here on
    # the same bound.
    chain = NativeYamlFixtures.merge_chain(9999)
    result = oracle("DevicesMap", chain, nil)
    assert result["accepted"] == true

    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("DevicesMap", chain)
  end

  # --- Safety ---------------------------------------------------------------

  test "worst-case duplicate handling on near-limit inputs stays linear" do
    # Duplicates inside a mapping whose key is dropped: the mapping is
    # composed once and never constructed (native skips the duplicate
    # check entirely), so the whole input must parse and finish quickly.
    dropped_dups =
      "~:\n" <>
        Enum.map_join(0..39_999, "", fn n -> " d_#{n}: 1\n" end) <>
        Enum.map_join(0..39_999, "", fn n -> " d_#{n}: 2\n" end) <>
        "k: 1\n"

    assert byte_size(dropped_dups) < 1_048_576

    started = System.monotonic_time(:millisecond)
    assert {:ok, %{"k" => "1"}} = NativeConfig.from_yaml("ConfigMap", dropped_dups)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_000, "dropped duplicates took #{elapsed}ms"

    # A large checked map: every entry is constructed at the result
    # boundary, so key and duplicate validation is the hot path.
    # Sized so the encoded output stays under the result budget as well.
    big_checked = Enum.map_join(0..69_999, "", fn n -> "k_#{n}: 1\n" end)

    assert byte_size(big_checked) < 1_048_576

    started = System.monotonic_time(:millisecond)

    assert {:ok, value} =
             NativeConfig.from_yaml("ConfigMap", big_checked)

    elapsed = System.monotonic_time(:millisecond) - started
    assert map_size(value) == 70_000
    assert elapsed < 1_000, "checked map took #{elapsed}ms"

    # Duplicates in the checked map reject just as fast.
    dup_checked = big_checked <> "k_4242: 2\n"
    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("ConfigMap", dup_checked)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_000, "duplicate check took #{elapsed}ms"
  end

  test "the deepest nesting that fits in the input bound rejects within the bound" do
    # The native scanner rejects flow and block nesting beyond 10_000
    # levels. yamerl has no such limit and its scan cost grows
    # super-linearly in flow depth, so deeper input must be rejected before
    # yamerl runs. Dropped values are the only place deep flows can be
    # accepted, which is why the boundary rows use them.

    # The deepest flow mapping that still fits in the 1 MiB input bound:
    # the five-byte-per-level shape reaches about 200k levels.
    deepest_map = Enum.reduce(1..199_990, "x", fn _i, acc -> "{a: #{acc}}" end)

    deep_yaml = "~:\n  k: " <> deepest_map <> "\n"
    assert byte_size(deep_yaml) < 1_048_576

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("ConfigMap", deep_yaml)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_000, "deep flow mapping took #{elapsed}ms"

    # The deepest pure flow sequence that fits: a single byte per level.
    seq_yaml = NativeYamlFixtures.deep_seq(524_000)
    assert byte_size(seq_yaml) < 1_048_576

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("ConfigMap", seq_yaml)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_000, "deep flow sequence took #{elapsed}ms"

    # Moderate nesting stays accepted and matches the native oracle.
    assert_matches(
      "ConfigMap",
      NativeYamlFixtures.deep_flow(400),
      nil,
      oracle("ConfigMap", NativeYamlFixtures.deep_flow(400), nil)
    )
  end

  test "high nesting work is rejected fast and realistic large configs decode within the bound" do
    # A single depth-9999 nested merge chain: the native oracle accepts it
    # (10_000-level scanner limit), but its flow nesting work exceeds
    # @max_flow_work, so ours must reject it before yamerl runs.
    chain = NativeYamlFixtures.merge_chain(9999)
    assert byte_size(chain) < 1_048_576

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("DevicesMap", chain)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_000, "deep merge chain took #{elapsed}ms"

    # Six such chains in one document (about 953 KB, under the input
    # bound): the same bound must reject the whole document fast.
    six_chains = Enum.map_join(1..6, "", fn k -> "d#{k}: " <> merge_chain_body() <> "\n" end)
    assert byte_size(six_chains) < 1_048_576

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("DevicesMap", six_chains)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_000, "six merge chains took #{elapsed}ms"

    # A moderate nested merge chain stays accepted and matches native.
    shallow = NativeYamlFixtures.merge_chain(400)

    started = System.monotonic_time(:millisecond)
    assert {:ok, _} = NativeConfig.from_yaml("DevicesMap", shallow)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_000, "shallow merge chain took #{elapsed}ms"

    assert_matches("DevicesMap", shallow, nil, oracle("DevicesMap", shallow, nil))

    # A realistic large config: 2_000 devices with five properties each,
    # merging one anchored template. This is the common production shape
    # and must decode well inside the bound, matching native.
    realistic = realistic_devices()
    assert byte_size(realistic) < 1_048_576

    started = System.monotonic_time(:millisecond)
    assert {:ok, value} = NativeConfig.from_yaml("DevicesMap", realistic)
    elapsed = System.monotonic_time(:millisecond) - started
    # the template key plus 2_000 devices
    assert map_size(value) == 2_001

    assert value["d1"] == %{
             "a" => "1",
             "b" => "2",
             "p1" => "v1",
             "p2" => "v1",
             "p3" => "v1",
             "p4" => "v1",
             "p5" => "v1"
           }

    assert elapsed < 1_000, "realistic devices took #{elapsed}ms"

    assert_matches("DevicesMap", realistic, nil, oracle("DevicesMap", realistic, nil))
  end

  # The body of the depth-9999 merge chain without its device key, so the
  # six-chain document can give each chain a distinct key.
  defp merge_chain_body do
    Enum.reduce(9999..1//-1, "{z: x}", fn i, acc -> "{a#{i}: x, <<: #{acc}}" end)
  end

  # 2_000 devices, five properties each, all merging an anchored two-
  # property template through an alias.
  defp realistic_devices do
    body =
      Enum.map_join(1..2_000, "", fn n ->
        ~s(d#{n}: {<<: *t, p1: "v#{n}", p2: "v#{n}", p3: "v#{n}", p4: "v#{n}", p5: "v#{n}"}\n)
      end)

    ~s(t: &t {a: "1", b: "2"}\n) <> body
  end

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
  # anchored subtree, so the cost grows as 9**(N-1). Expansion charges at
  # parse time and construction re-charges the folded tree, so the last
  # level's tail lands at: 4 aliases about 983k charged nodes (just under
  # the 1M-node budget), 5 just over.
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

    # (c) Four tail aliases charge about 983k expanded nodes, just under
    # the 1M-node budget, so the rejection in (b) comes from the budget,
    # not a shape error. The native driver has no verdict to compare
    # against: its own aliasing-ratio check (named divergence below)
    # rejects this input too, strictly stricter than our bound.
    assert {:ok, value} = NativeConfig.from_yaml("DevicesMap", merge_bomb(4))
    assert value["d6"] == %{"k" => "v"}

    # Five tail aliases cross the budget just over the 1M-node limit.
    assert {:error, %Error{kind: :invalid_native_config}} =
             NativeConfig.from_yaml("DevicesMap", merge_bomb(5))
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
