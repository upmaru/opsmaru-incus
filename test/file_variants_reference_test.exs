defmodule Opsmaru.Incus.FileVariantsReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Files, Server}
  alias Opsmaru.TestSupport.HTTPFixture
  @driver Path.expand("../../.integration/file-variants-driver", __DIR__)
  @bytes :binary.copy(<<0, 255, 128, 13, 10>>, 100)
  @extensions ~w(container_backup custom_volume_backup storage_bucket_backup backup_override_name custom_volume_iso direct_backup directory_manipulation file_append file_symlinks)
  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./filevariants"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-f-variants-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "twelve native volume/file/archive helpers agree on wire paths, binary bytes, headers and accepted operations",
       %{root: root} do
    {client, fixture} = backend(root, :native)

    for action <-
          ~w(volume-read volume-create volume-delete instance-export volume-export bucket-export instance-direct volume-direct bucket-direct volume-import iso-import bucket-import) do
      before_files = File.ls!(root) |> Enum.sort()

      expected =
        oracle(%{
          action: action,
          socket: client.connection.address,
          project: "fixture +",
          root: root,
          payload: Base.encode64(@bytes)
        })

      refute expected["error"], inspect(expected)
      assert File.ls!(root) |> Enum.sort() == before_files
      native = HTTPFixture.requests(fixture) |> List.last()
      assert {:ok, result} = call(action, client)
      actual = HTTPFixture.requests(fixture) |> List.last()
      assert actual.method == native.method
      assert actual.target == native.target

      if String.ends_with?(action, "direct") do
        assert native.headers["accept"] == "application/octet-stream"
        assert actual.headers["accept"] == native.headers["accept"]
        assert subset?(Jason.decode!(actual.body), Jason.decode!(native.body))
      else
        assert actual.body == native.body

        for header <-
              ~w(content-type x-incus-name x-incus-type x-incus-write x-incus-uid x-incus-gid x-incus-mode) do
          assert actual.headers[header] == native.headers[header]
        end
      end

      cond do
        action == "volume-read" ->
          assert_receive {:sink, @bytes}
          assert result.result.uid == expected["info"]["UID"]
          assert result.result.gid == expected["info"]["GID"]
          assert result.result.mode == expected["info"]["Mode"]
          assert Base.decode64!(expected["bytes"]) == @bytes

        String.ends_with?(action, "export") or String.ends_with?(action, "direct") ->
          assert_receive {:sink, @bytes}
          assert Base.decode64!(expected["bytes"]) == @bytes
          assert result.bytes == byte_size(@bytes)

        String.ends_with?(action, "import") ->
          assert result.operation == "/1.0/operations/archive"
          assert result.metadata["id"] == expected["operation"]["id"]
          assert result.metadata["status_code"] == 103

        true ->
          :ok
      end
    end
  end

  test "native volume directory entries remain metadata instead of binary sink data", %{
    root: root
  } do
    {client, _} = backend(root, :directory)

    expected =
      oracle(%{
        action: "volume-read",
        socket: client.connection.address,
        project: "fixture +",
        root: root
      })

    refute expected["error"], inspect(expected)
    assert {:ok, transfer} = call("volume-read", client)
    assert transfer.result.entries == expected["info"]["Entries"]
    assert transfer.result.type == "directory"
    refute_receive {:sink, _}, 30
  end

  test "explicit member selection survives direct backup handoff and unsupported/invalid calls do no I/O",
       %{root: root} do
    {client, fixture} = backend(root, :native)
    member = Incus.member(client, "selected")
    assert {:ok, _} = call("volume-direct", member)
    assert_receive {:sink, @bytes}
    request = HTTPFixture.requests(fixture) |> List.last()
    assert URI.decode_query(URI.parse(request.target).query)["target"] == "selected"
    count = length(HTTPFixture.requests(fixture))
    unavailable = %{client | server: %Server{api_extensions: []}}

    for action <-
          ~w(instance-export volume-export bucket-export instance-direct volume-direct bucket-direct volume-import iso-import bucket-import) do
      assert {:error, %Error{kind: :unsupported_extension}} = call(action, unavailable)
    end

    assert {:error, %Error{kind: :invalid_file_options}} =
             Files.volume_delete(client, "pool", "custom", "volume", self())

    assert length(HTTPFixture.requests(fixture)) == count
  end

  test "volume deletion and archive POST errors preserve native rejection and uncertainty without replay",
       %{root: root} do
    {client, fixture} = backend(root, :reject)

    for action <- ~w(volume-read volume-create volume-delete volume-import volume-direct) do
      assert {:error, %Error{kind: :native, error_code: 777, http_status: 409}} =
               call(action, client)
    end

    assert length(HTTPFixture.requests(fixture)) == 5
    {lost, fixture} = backend(root, :lost)

    for action <- ~w(volume-delete volume-import volume-direct) do
      assert {:error, %Error{kind: :uncertain}} = call(action, lost)
    end

    assert length(HTTPFixture.requests(fixture)) == 3
  end

  defp call(action, client) do
    parent = self()

    sink = fn bytes ->
      send(parent, {:sink, bytes})
      :ok
    end

    case action do
      "volume-read" ->
        Files.volume_read(client, "pool +", "custom", "volume +", "/path +", sink)

      "volume-create" ->
        Files.volume_create(client, "pool +", "custom", "volume +", "/path +", [@bytes],
          uid: 7,
          gid: 8,
          mode: 0o640,
          type: "file",
          write_mode: "overwrite"
        )

      "volume-delete" ->
        Files.volume_delete(client, "pool +", "custom", "volume +", "/path +")

      "instance-export" ->
        Files.backup_download(client, "instance +", "backup +", sink)

      "volume-export" ->
        Files.volume_backup_download(client, "pool +", "custom", "volume +", "backup +", sink)

      "bucket-export" ->
        Files.bucket_backup_download(client, "pool +", "bucket +", "backup +", sink)

      "instance-direct" ->
        Files.backup_stream(client, {:instance, "instance +"}, %{"name" => "native"}, sink)

      "volume-direct" ->
        Files.backup_stream(
          client,
          {:volume, "pool +", "custom", "volume +"},
          %{"name" => "native"},
          sink
        )

      "bucket-direct" ->
        Files.backup_stream(client, {:bucket, "pool +", "bucket +"}, %{"name" => "native"}, sink)

      "volume-import" ->
        Files.volume_import(client, "pool +", [@bytes], name: "native")

      "iso-import" ->
        Files.volume_import(client, "pool +", [@bytes], name: "native", type: :iso)

      "bucket-import" ->
        Files.bucket_import(client, "pool +", [@bytes], name: "native")
    end
  end

  defp backend(root, outcome) do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, Atom.to_string(outcome) <> ".sock"),
         handler: fn req ->
           path = URI.parse(req.target).path

           cond do
             path == "/1.0" ->
               %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{api_version: "1.0", api_extensions: @extensions, environment: %{}}
                 }
               }

             outcome == :lost ->
               %{raw: ""}

             outcome == :reject ->
               %{status: 409, body: %{type: "error", error_code: 777, error: "native"}}

             outcome == :directory ->
               %{
                 status: 200,
                 headers: %{
                   "x-incus-type" => "directory",
                   "x-incus-uid" => "7",
                   "x-incus-gid" => "8",
                   "x-incus-mode" => "0640"
                 },
                 body: %{type: "sync", metadata: ["one", "two"]}
               }

             req.method == "GET" or String.ends_with?(path, "/backups") ->
               %{
                 raw: [
                   "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(@bytes)}\r\nX-Incus-type: file\r\nX-Incus-uid: 7\r\nX-Incus-gid: 8\r\nX-Incus-mode: 0640\r\n\r\n",
                   @bytes
                 ]
               }

             req.method == "DELETE" or String.ends_with?(path, "/files") ->
               %{status: 200, body: %{type: "sync", metadata: %{}}}

             true ->
               %{
                 status: 202,
                 body: %{
                   type: "async",
                   operation: "/1.0/operations/archive",
                   metadata: %{id: "archive", status_code: 103}
                 }
               }
           end
         end},
        id: make_ref()
      )

    client = %Incus{
      connection:
        Connection.unix!(HTTPFixture.endpoint(fixture).socket,
          owner: :fixture,
          project: "fixture +"
        ),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: @extensions}
    }

    {client, fixture}
  end

  defp oracle(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, out) do
    receive do
      {^port, {:data, bytes}} -> collect(port, out <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(out)
      {^port, {:exit_status, status}} -> flunk("native file helper failed #{status}: #{out}")
    after
      10_000 ->
        Port.close(port)
        flunk("native file helper deadline")
    end
  end

  defp subset?(actual, expected) when is_map(actual) and is_map(expected),
    do: Enum.all?(actual, fn {k, v} -> Map.has_key?(expected, k) and subset?(v, expected[k]) end)

  defp subset?(actual, expected), do: actual == expected
end
