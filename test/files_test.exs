defmodule Opsmaru.Incus.FilesTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Files, Server}
  alias Opsmaru.TestSupport.HTTPFixture

  test "native files preserve binary bytes/mode/identity and directories decode separately" do
    root = Path.join(System.tmp_dir!(), "op-files-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    bytes = <<0, 255, 128, 42>>
    directory = Jason.encode!(%{type: "sync", metadata: ["one", "two"]})

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "s"),
         handler: fn request ->
           cond do
             request.method == "POST" ->
               assert request.body == bytes
               assert request.headers["x-incus-mode"] == "0640"
               assert request.headers["x-incus-uid"] == "1000"
               %{status: 200, body: %{type: "sync", metadata: nil}}

             String.contains?(request.target, "directory") ->
               %{
                 raw: [
                   "HTTP/1.1 200 OK\r\nX-Incus-type: directory\r\nContent-Length: ",
                   Integer.to_string(byte_size(directory)),
                   "\r\n\r\n",
                   directory
                 ]
               }

             true ->
               %{
                 raw: [
                   "HTTP/1.1 200 OK\r\nX-Incus-type: file\r\nX-Incus-uid: 1000\r\nX-Incus-gid: 1001\r\nX-Incus-mode: 0640\r\nContent-Length: 4\r\n\r\n",
                   bytes
                 ]
               }
           end
         end}
      )

    client = %Incus{
      connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: ["file_append", "directory_manipulation"]}
    }

    parent = self()

    assert {:ok, downloaded} =
             Files.read(client, "fixture", "/native", fn bytes ->
               send(parent, {:bytes, bytes})
               :ok
             end)

    assert_receive {:bytes, ^bytes}
    assert downloaded.result.uid == 1000
    assert downloaded.result.gid == 1001
    assert downloaded.result.mode == 0o640

    assert {:ok, directory} =
             Files.read(client, "fixture", "/directory", fn _ ->
               flunk("directory passed to binary file sink")
             end)

    assert directory.result.entries == ["one", "two"]

    assert {:ok, _} =
             Files.create(client, "fixture", "/native", [bytes],
               uid: 1000,
               gid: 1001,
               mode: 0o640,
               write_mode: "append"
             )

    [_, _, created] = HTTPFixture.requests(fixture)
    assert URI.decode_query(URI.parse(created.target).query)["path"] == "/native"
  end
end
