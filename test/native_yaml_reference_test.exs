defmodule Opsmaru.Incus.NativeYamlReferenceTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.NativeConfig
  @moduletag timeout: 120_000
  @driver Path.expand("../../.integration/incus-yaml-driver", __DIR__)

  # Contract: from_yaml/3 returns exactly the unchanged native go-yaml v4 +
  # Incus api result, or rejects. It never accepts what native rejects and
  # never returns a different value. Rows were probed against the native
  # driver in test/reference/nativeyaml; many are deliberately outside the
  # supported subset and must simply not violate the contract.
  @contract_matrix [
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
    {"ConfigMap", "a: 1\n---\n'bad\n", nil}
    # nesting beyond the native 10_000-level scanner limit (dropped values,
    # which are the only place deep flows can be accepted at all)
    # nested literal merge chains within the flow nesting work bound
  ]

  # Realistic Incus documents inside the subset: native accepts them and so
  # must we, with the same value.
  @realistic [
    {"ConfigMap",
     """
     limits.cpu: 2
     limits.memory: 4GiB
     security.nesting: true
     boot.autostart: false
     user.created: "2024-01-01"
     user.mode: 0755
     user.ratio: 0.5
     user.count: 1_000
     user.empty:
     user.quoted: 'it''s "quoted"'
     user.user-data: |
       #cloud-config
       runcmd:
         - [ sh, -c, "if [[ -f /etc/x ]]; then echo ok; fi" ]
     user.folded: >
       folded
       text
     """, nil},
    {"ConfigMap", "{limits.cpu: 4, security.privileged: false, user.note: \"a: b # c\"}\n", nil},
    {"ConfigMap", "---\nlimits.cpu: 1\n...\n", %{"limits.memory" => "1GiB", "limits.cpu" => "8"}},
    {"ConfigMap", "# only a comment\n", %{"limits.cpu" => "8"}},
    {"ConfigMap", "~\n", %{"limits.cpu" => "8"}},
    {"DevicesMap",
     """
     nic_base: &nic
       type: nic
       nictype: bridged
       parent: incusbr0
     eth0:
       <<: *nic
       name: eth0
     eth1:
       <<: *nic
       name: eth1
       parent: incusbr1
     root:
       type: disk
       path: /
       pool: default
       size: 20GiB
     gpu0: {type: gpu, gputype: physical, id: 0}
     proxy0:
       type: proxy
       listen: tcp:0.0.0.0:80
       connect: tcp:127.0.0.1:8080
     """, nil},
    {"DevicesMap",
     """
     disk_base: &disk
       type: disk
       pool: default
     ssd: &ssd
       pool: fast
     data:
       <<: [*ssd, *disk]
       path: /data
     """, %{"data" => %{"readonly" => "true"}, "other" => %{"type" => "none"}}},
    {"DevicesMap", "eth0: {type: nic, network: incusbr0, <<: {name: eth0, mtu: 1500}}\n", nil}
  ]

  # Recorded differences: native accepts these, the subset rejects them.
  @outside_subset [
    {"explicit tag", "ConfigMap", "k: !!str 5\n"},
    {"directive", "ConfigMap", "%YAML 1.1\n---\na: 1\n"},
    {"second document", "ConfigMap", "a: 1\n---\nb: 2\n"},
    {"null key", "ConfigMap", "~: 1\nb: 2\n"},
    {"non-string key", "ConfigMap", "0755: 1\n"},
    {"anchor on a flow collection", "DevicesMap", "d0: &d0 {k: v}\nd1: *d0\n"},
    {"date-like plain scalar", "ConfigMap", "k: 2024-02-30\n"},
    {"underscore dot float", "ConfigMap", "k: .5_5\n"},
    {"more than 100 aliases", "DevicesMap",
     "b: &b\n  type: nic\n" <> Enum.map_join(1..101, "", &"d#{&1}:\n  <<: *b\n")},
    {"tab-indented later document", "ConfigMap", "a: 1\n---\nb:\n\t- x\n"}
  ]

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./nativeyaml"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "realistic Incus documents decode exactly like the native decoder" do
    for {{type, yaml, existing}, native} <- Enum.zip(@realistic, oracle(@realistic)) do
      assert native["accepted"], "native rejected #{inspect(yaml)}"
      assert NativeConfig.from_yaml(type, yaml, existing) == {:ok, native["value"]}, yaml
    end
  end

  test "every matrix row satisfies the contract" do
    rows = Enum.zip(@contract_matrix, oracle(@contract_matrix))

    Enum.each(rows, fn {{type, yaml, existing}, native} ->
      assert_contract(type, yaml, existing, native)
    end)

    accepted =
      Enum.count(rows, fn {{t, y, e}, _} -> match?({:ok, _}, NativeConfig.from_yaml(t, y, e)) end)

    assert accepted > 80
  end

  test "randomized documents satisfy the contract" do
    :rand.seed(:exsss, {1, 2, 3})
    cases = for _ <- 1..400, do: random_case()
    results = oracle(cases)

    Enum.each(Enum.zip(cases, results), fn {{type, yaml, existing}, native} ->
      assert_contract(type, yaml, existing, native)
    end)

    assert Enum.count(results, & &1["accepted"]) > 100
  end

  test "recorded differences: native accepts, the subset rejects" do
    cases = Enum.map(@outside_subset, fn {_, type, yaml} -> {type, yaml, nil} end)

    for {{label, type, yaml}, native} <- Enum.zip(@outside_subset, oracle(cases)) do
      assert native["accepted"], "native no longer accepts #{label}"

      assert {:error, %Error{kind: :invalid_native_config}} = NativeConfig.from_yaml(type, yaml),
             label
    end
  end

  test "pathological documents are rejected within the decode deadline" do
    deep = fn d -> String.duplicate("[", d) <> "x" <> String.duplicate("]", d) end
    flat = "[" <> Enum.map_join(1..200_000, ", ", fn _ -> "x" end) <> "]"
    chain = Enum.reduce(9_999..1//-1, "{z: x}", fn i, acc -> "{a#{i}: x, <<: #{acc}}" end)

    for {type, yaml} <- [
          {"ConfigMap", "k: " <> deep.(10_000) <> "\n"},
          {"ConfigMap", "~:\n  k: " <> deep.(200_000) <> "\n"},
          {"ConfigMap", flat <> ": 1\n"},
          {"ConfigMap", "<<: [" <> flat <> "]\n"},
          {"DevicesMap", Enum.map_join(1..6, "", &"d#{&1}: #{chain}\n")}
        ] do
      started = System.monotonic_time(:millisecond)
      assert {:error, %Error{}} = NativeConfig.from_yaml(type, yaml)
      assert System.monotonic_time(:millisecond) - started < 3_000
    end
  end

  test "near-limit realistic documents decode quickly and leave no worker or messages" do
    yaml = Enum.map_join(1..20_000, "", &"user.key#{&1}: \"value #{&1}\"\n")
    before = Process.list() |> length()
    started = System.monotonic_time(:millisecond)
    assert {:ok, value} = NativeConfig.from_yaml("ConfigMap", yaml)
    assert map_size(value) == 20_000
    assert System.monotonic_time(:millisecond) - started < 1_000

    assert {:error, _} =
             NativeConfig.from_yaml(
               "ConfigMap",
               "k: [" <> String.duplicate("[x, ", 50_000) <> "]: 1\n"
             )

    Process.sleep(50)
    assert length(Process.list()) <= before
    refute_received _
  end

  test "bounds, atoms, raising and yamerl state" do
    env = :application.get_all_env(:yamerl)
    assert {:error, _} = NativeConfig.from_yaml("ConfigMap", String.duplicate("a", 1_048_577))
    assert {:error, _} = NativeConfig.from_yaml("ConfigMap", <<0xFF, 0xFE>>)
    assert {:error, _} = NativeConfig.from_yaml("ConfigMap", "a: 1\u0000")
    assert {:error, _} = NativeConfig.from_yaml("Other", "a: 1")
    assert {:error, _} = NativeConfig.from_yaml("ConfigMap", "a: 1", %{"x" => 1})

    keys = for i <- 1..200, do: "opsmaru_yaml_atom_probe_#{i}"
    {:ok, _} = NativeConfig.from_yaml("ConfigMap", Enum.map_join(keys, "", &"#{&1}: #{&1}\n"))
    refute Enum.any?(keys, &atom_exists?/1)

    garbage = ["{", "[", "a: [", "a: 'x", "&a", "*a", ": :", "- - -", "? ? ?", "a: *missing"]
    cases = Enum.map(garbage, &{"ConfigMap", &1, nil})

    for {{type, yaml, existing}, native} <- Enum.zip(cases, oracle(cases)) do
      assert_contract(type, yaml, existing, native)
    end

    refute inspect(NativeConfig.from_yaml("ConfigMap", "secret: [")) =~ "secret"
    assert :application.get_all_env(:yamerl) == env
  end

  defp assert_contract(type, yaml, existing, native) do
    case NativeConfig.from_yaml(type, yaml, existing) do
      {:ok, value} ->
        assert native["accepted"], "accepted what native rejects: #{inspect(yaml)}"
        assert value == native["value"], "value differs from native: #{inspect(yaml)}"

      {:error, %Error{kind: :invalid_native_config}} ->
        :ok
    end
  end

  defp random_case do
    scalars =
      ~w(true no ~ null 0 -1 +7 0755 0x1F 0b101 1_000 08 1.5 -0.0 .5 1e3 .5e2 .inf .NaN 2024-01-01 9223372036854775808 abc @x) ++
        ["a b", "*.example.com"]

    val = fn ->
      s = Enum.random(scalars)

      case :rand.uniform(5) do
        1 -> "\"" <> s <> "\""
        2 -> "'" <> s <> "'"
        3 -> "!!float " <> s
        _ -> s
      end
    end

    if :rand.uniform(2) == 1 do
      yaml =
        Enum.map_join(1..:rand.uniform(4), "", fn i ->
          Enum.random([
            "k#{i}: #{val.()}\n",
            "m#{i}: &m#{i}\n  a: #{val.()}\n",
            "<<: *m#{i - 1}\n",
            "~: &n#{i} {a: #{val.()}}\n",
            "#{Enum.random(["1", "true", "'1'"])}: #{val.()}\n"
          ])
        end)

      {"ConfigMap", yaml, Enum.random([nil, %{"k1" => "old"}])}
    else
      yaml =
        "base: &base\n  type: nic\n  mtu: #{val.()}\n" <>
          Enum.map_join(1..:rand.uniform(3), "", fn i ->
            Enum.random([
              "eth#{i}:\n  <<: *base\n  name: #{val.()}\n",
              "eth#{i}: {<<: *base, x: #{val.()}}\n",
              "eth#{i}:\n  <<: [*base, {z: #{val.()}}]\n  #{Enum.random(["p", "1", "on"])}: #{val.()}\n"
            ])
          end)

      {"DevicesMap", yaml, Enum.random([nil, %{"eth1" => %{"old" => "1"}}])}
    end
  end

  defp atom_exists?(binary) do
    _ = String.to_existing_atom(binary)
    true
  rescue
    ArgumentError -> false
  end

  defp oracle(cases) do
    input =
      Jason.encode!(%{
        cases:
          Enum.map(cases, fn {type, yaml, existing} ->
            %{type: type, yaml: yaml, existing: existing}
          end)
      })

    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, input <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} -> collect(port, data <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(data)["results"]
      {^port, {:exit_status, status}} -> flunk("native YAML oracle failed #{status}: #{data}")
    after
      30_000 ->
        Port.close(port)
        flunk("native YAML oracle deadline")
    end
  end
end
