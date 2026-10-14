defmodule Opsmaru.Incus.FileReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Files, Server}
  alias Opsmaru.TestSupport.HTTPFixture
  @driver Path.expand("../.integration/incus-file-driver", __DIR__)
  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "official file and backup clients agree on binary bytes, native headers and accepted identities" do
    root = Path.join(System.tmp_dir!(), "op-file-ref-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    bytes = <<0, 255, 128, 42>>

    extensions = [
      "file_append",
      "container_backup",
      "container_backup_override_pool",
      "backup_override_name",
      "backup_override_config"
    ]

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "s"),
         handler: fn request ->
           cond do
             URI.parse(request.target).path == "/1.0" ->
               %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{api_version: "1.0", api_extensions: extensions, environment: %{}}
                 }
               }

             request.method == "GET" ->
               %{
                 raw: [
                   "HTTP/1.1 200 OK\r\nX-Incus-type: file\r\nX-Incus-uid: 1000\r\nX-Incus-gid: 1001\r\nX-Incus-mode: 0640\r\nContent-Length: 4\r\n\r\n",
                   bytes
                 ]
               }

             URI.parse(request.target).path == "/1.0/instances" ->
               %{
                 status: 202,
                 body: %{
                   type: "async",
                   operation: "/1.0/operations/backup",
                   metadata: %{id: "backup", status_code: 103}
                 }
               }

             true ->
               %{status: 200, body: %{type: "sync", metadata: nil}}
           end
         end}
      )

    client = %Incus{
      connection:
        Connection.unix!(HTTPFixture.endpoint(fixture).socket,
          owner: :fixture,
          project: "fixture",
          member: "member"
        ),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: extensions}
    }

    for {action, body} <- [
          {"file_read", %{}},
          {"file_create",
           %{UID: 1000, GID: 1001, Mode: 0o640, Type: "file", WriteMode: "append"}},
          {"backup_import",
           %{
             Name: "restored",
             PoolName: "pool",
             Config: ["user.note=native"],
             Devices: ["root,pool=pool"]
           }}
        ] do
      input = Path.join(root, action <> ".json")

      File.write!(
        input,
        Jason.encode!(%{
          socket: client.connection.address,
          project: "fixture",
          target: "member",
          transfer: action,
          body: body,
          payload: Base.encode64(bytes)
        })
      )

      {out, status} = System.cmd(@driver, [input], stderr_to_stdout: true)
      assert status == 0, out
      oracle = Jason.decode!(out)
      refute oracle["error"], out
      expected = HTTPFixture.requests(fixture) |> List.last()

      case action do
        "file_read" ->
          parent = self()

          assert {:ok, read} =
                   Files.read(client, "fixture", "/native", fn data ->
                     send(parent, {:bytes, data})
                     :ok
                   end)

          assert_receive {:bytes, ^bytes}
          assert Base.decode64!(oracle["bytes"]) == bytes
          assert read.result.uid == oracle["response"]["UID"]
          assert read.result.mode == oracle["response"]["Mode"]

        "file_create" ->
          assert {:ok, _} =
                   Files.create(client, "fixture", "/native", [bytes],
                     uid: 1000,
                     gid: 1001,
                     mode: 0o640,
                     type: "file",
                     write_mode: "append"
                   )

        "backup_import" ->
          assert {:ok, accepted} =
                   Files.backup_import(client, [bytes],
                     name: "restored",
                     pool: "pool",
                     config: ["user.note=native"],
                     devices: ["root,pool=pool"]
                   )

          assert accepted.operation == "/1.0/operations/backup"
          assert oracle["operation"]["id"] == "backup"
      end

      actual = HTTPFixture.requests(fixture) |> List.last()
      assert actual.method == expected.method
      assert URI.parse(actual.target).path == URI.parse(expected.target).path

      assert URI.decode_query(URI.parse(actual.target).query) ==
               URI.decode_query(URI.parse(expected.target).query)

      assert actual.body == expected.body

      native = fn headers ->
        Map.filter(headers, fn {key, _} -> String.starts_with?(key, "x-incus-") end)
      end

      assert native.(actual.headers) == native.(expected.headers)
    end
  end
end
