defmodule Opsmaru.Incus.BackupVariantsTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Files, Server}
  alias Opsmaru.TestSupport.HTTPFixture

  test "native volume/bucket archive handoffs and direct backup POST remain binary and bounded" do
    root = Path.join(System.tmp_dir!(), "op-backup-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    bytes = <<0, 255, 128, 42>>

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "s"),
         handler: fn request ->
           if request.method == "GET" or
                String.ends_with?(URI.parse(request.target).path, "/backups") do
             if request.method == "POST" do
               assert request.headers["accept"] == "application/octet-stream"
               assert Jason.decode!(request.body)["name"] == "native"
             end

             %{raw: ["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n", bytes]}
           else
             assert request.body == bytes
             assert request.headers["content-type"] == "application/octet-stream"
             assert request.headers["x-incus-name"] == "native"

             %{
               status: 202,
               body: %{
                 type: "async",
                 operation: "/1.0/operations/archive",
                 metadata: %{id: "archive", status_code: 103}
               }
             }
           end
         end}
      )

    client = %Incus{
      connection:
        Connection.unix!(HTTPFixture.endpoint(fixture).socket,
          owner: :fixture,
          max_chunk_bytes: 64
        ),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{
        api_extensions: [
          "custom_volume_backup",
          "backup_override_name",
          "custom_volume_iso",
          "storage_bucket_backup",
          "direct_backup"
        ]
      }
    }

    parent = self()

    sink = fn data ->
      send(parent, {:bytes, data})
      :ok
    end

    assert {:ok, _} =
             Files.volume_backup_download(client, "pool", "custom", "volume", "backup", sink)

    assert_receive {:bytes, ^bytes}
    assert {:ok, _} = Files.bucket_backup_download(client, "pool", "bucket", "backup", sink)
    assert_receive {:bytes, ^bytes}

    for resource <- [
          {:instance, "instance"},
          {:volume, "pool", "custom", "volume"},
          {:bucket, "pool", "bucket"}
        ] do
      assert {:ok, _} = Files.backup_stream(client, resource, %{"name" => "native"}, sink)
      assert_receive {:bytes, ^bytes}
    end

    assert {:ok, response} = Files.volume_import(client, "pool", [bytes], name: "native")
    assert response.operation == "/1.0/operations/archive"
    assert {:ok, _} = Files.volume_import(client, "pool", [bytes], name: "native", type: :iso)
    assert {:ok, _} = Files.bucket_import(client, "pool", [bytes], name: "native")
    requests = HTTPFixture.requests(fixture)
    assert length(requests) == 8
    assert Enum.at(requests, 6).headers["x-incus-type"] == "iso"
    assert URI.parse(Enum.at(requests, 7).target).path == "/1.0/storage-pools/pool/buckets"
    unsupported = %{client | server: %Server{api_extensions: []}}

    assert {:error, %Error{kind: :unsupported_extension}} =
             Files.volume_import(unsupported, "pool", [bytes])

    assert {:error, %Error{kind: :unsupported_extension}} =
             Files.backup_stream(unsupported, {:instance, "instance"}, %{}, sink)

    assert length(HTTPFixture.requests(fixture)) == 8
  end
end
