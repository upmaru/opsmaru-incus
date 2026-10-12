defmodule Opsmaru.Incus.FileHeadersReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, FileHeaders, Files, Server}
  alias Opsmaru.TestSupport.HTTPFixture
  @driver Path.expand("../../.integration/file-headers-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./fileheaders"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "native ownership defaults, signed integers, leading zeros and overflow" do
    for value <- [
          "",
          "0",
          "-1",
          "+42",
          "-0001",
          String.duplicate("0", 100) <> "42",
          "9223372036854775807",
          "-9223372036854775808",
          "9223372036854775808",
          "-9223372036854775809",
          " 42",
          "42\n",
          "42x",
          "１２"
        ] do
      compare([{"X-Incus-uid", value}, {"x-incus-gid", value}])
    end

    compare([])
  end

  test "native decimal gate, base-zero permission mask and malformed-octal fallback" do
    for value <- [
          "0640",
          "644",
          "07777",
          "0777777777777777777777",
          "08",
          "0999",
          "0",
          "000",
          "+0640",
          "-0640",
          "-1",
          "-0001",
          "-9223372036854775808",
          "9223372036854775807",
          "9223372036854775808",
          "0x1ff",
          "0o777",
          "0b111",
          "0_640",
          "640\n",
          " 640",
          "",
          "bad"
        ] do
      compare([{"X-Incus-mode", value}])
    end
  end

  test "case-insensitive first-value semantics and native type/write defaults" do
    for value <- ["", "file", "directory", "symlink", "native-future", "雪"] do
      compare([{"x-incus-type", value}, {"X-INCUS-WRITE", value}])
    end

    compare([{"X-Incus-mode", "0640"}, {"x-incus-mode", "0777"}])
    assert {:ok, %{mode: 0o640}} = FileHeaders.parse(%{"X-INCUS-MODE" => "0640"})
  end

  test "invalid structure and aggregate header bounds fail without exposing input" do
    for headers <- [
          nil,
          [nil],
          [{:key, "private"}],
          [{"key", nil}],
          [{"key", <<255>>}],
          List.duplicate({"key", "v"}, 129),
          [{"key", String.duplicate("private", 2400)}],
          List.duplicate({"key", String.duplicate("private", 20)}, 128)
        ] do
      assert {:error, %Error{kind: :invalid_file_headers} = error} = FileHeaders.parse(headers)
      refute inspect(error) =~ "private"
    end
  end

  test "binary file downloads use native mode fallback and first duplicate headers" do
    root = Path.join(System.tmp_dir!(), "op-header-wire-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    pairs = [
      {"X-Incus-mode", "644"},
      {"X-Incus-mode", "0777"},
      {"X-Incus-uid", "9223372036854775808"},
      {"X-Incus-gid", "-42"},
      {"X-Incus-write", "native-write"}
    ]

    wire = Enum.map(pairs, fn {key, value} -> [key, ": ", value, "\r\n"] end)

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "s"),
         handler: fn _ ->
           %{raw: ["HTTP/1.1 200 OK\r\n", wire, "Content-Length: 4\r\n\r\n", <<0, 255, 128, 42>>]}
         end}
      )

    client = %Incus{
      connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{}
    }

    parent = self()

    assert {:ok, transfer} =
             Files.read(client, "instance", "/file", fn bytes ->
               send(parent, {:bytes, bytes})
               :ok
             end)

    assert_receive {:bytes, <<0, 255, 128, 42>>}
    expected = oracle(pairs)
    actual = Map.take(transfer.result, [:uid, :gid, :mode, :type, :write_mode])
    assert Map.new(actual, fn {key, value} -> {Atom.to_string(key), value} end) == expected
    assert transfer.result.mode == 132
    assert length(HTTPFixture.requests(fixture)) == 1
  end

  defp compare(headers) do
    {:ok, actual} = FileHeaders.parse(headers)
    expected = oracle(headers)
    assert Map.new(actual, fn {key, value} -> {Atom.to_string(key), value} end) == expected
  end

  defp oracle(headers) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{headers: Enum.map(headers, &Tuple.to_list/1)}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)

      {^port, {:exit_status, status}} ->
        flunk("native file-header oracle failed #{status}: #{data}")
    after
      5_000 ->
        Port.close(port)
        flunk("native file-header oracle deadline")
    end
  end
end
