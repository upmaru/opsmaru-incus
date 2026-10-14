defmodule Opsmaru.Incus.CopyTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Copy, Error, Server}
  alias Opsmaru.TestSupport.HTTPFixture
  @driver Path.expand("../.integration/incus-copy-driver", __DIR__)
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

  test "official local instance, snapshot and volume copies agree on native writable configuration" do
    root = Path.join(System.tmp_dir!(), "op-copy-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    extensions = [
      "storage_api_local_volume_handling",
      "container_copy_project",
      "storage_api_project",
      "storage_api_remote_volume_handling",
      "storage_api_remote_volume_snapshot_copy"
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

             request.method == "POST" ->
               %{
                 status: 202,
                 body: %{
                   type: "async",
                   operation: "/1.0/operations/copy",
                   metadata: %{id: "copy", status_code: 103}
                 }
               }

             String.contains?(request.target, "/operations/") ->
               %{status: 200, body: %{type: "sync", metadata: %{id: "copy", status_code: 200}}}

             true ->
               %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{name: "fixture", type: "container", location: ""}
                 }
               }
           end
         end}
      )

    client = %Incus{
      connection:
        Connection.unix!(HTTPFixture.endpoint(fixture).socket,
          owner: :fixture,
          project: "fixture"
        ),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: extensions, environment: %{}}
    }

    for {action, model, call} <- [
          {"copy_instance_local",
           %{
             "name" => "fixture",
             "type" => "container",
             "config" => %{"volatile.base_image" => "native-image", "user.note" => "native"},
             "devices" => %{},
             "profiles" => ["default"],
             "ephemeral" => true
           }, fn data -> Copy.instance(client, client, data, name: "copy") end},
          {"copy_snapshot_local",
           %{
             "name" => "fixture/snapshot",
             "config" => %{},
             "profiles" => ["default"],
             "ephemeral" => true
           }, fn data -> Copy.snapshot(client, client, "fixture", data, name: "copy") end},
          {"copy_volume_local",
           %{
             "name" => "volume",
             "type" => "custom",
             "location" => "none",
             "config" => %{"size" => "10GiB"},
             "description" => "native",
             "content_type" => "filesystem"
           },
           fn data ->
             Copy.volume(client, client, "target-pool", "source-pool", data, name: "copy")
           end}
        ] do
      input = Path.join(root, action <> ".json")

      File.write!(
        input,
        Jason.encode!(%{
          socket: client.connection.address,
          project: "fixture",
          transfer: action,
          body: model
        })
      )

      {out, status} = System.cmd(@driver, [input], stderr_to_stdout: true)
      assert status == 0, out
      refute Jason.decode!(out)["error"], out

      expected =
        HTTPFixture.requests(fixture) |> Enum.filter(&(&1.method == "POST")) |> List.last()

      assert {:ok, accepted} = call.(model)
      assert accepted.mode == :local
      assert accepted.target.url == "/1.0/operations/copy"
      assert accepted.target.response.metadata.data["status_code"] == 103
      actual = HTTPFixture.requests(fixture) |> List.last()
      assert actual.method == expected.method
      assert actual.target == expected.target
      left = Jason.decode!(expected.body)
      right = Jason.decode!(actual.body)
      # The Go codec adds zero-valued DTO fields; all explicitly prepared native
      # fields, including source configuration, must match those official values.
      assert subset?(right, left), inspect({right, left})
    end

    input = Path.join(root, "snapshot-migration.json")
    body = %{"name" => "parent/snapshot", "migration" => true}

    File.write!(
      input,
      Jason.encode!(%{
        socket: client.connection.address,
        project: "fixture",
        action: "MigrateStoragePoolVolume",
        args: ["source-pool", body]
      })
    )

    {out, status} = System.cmd(@driver, [input], stderr_to_stdout: true)
    assert status == 0, out
    refute Jason.decode!(out)["error"], out
    expected = HTTPFixture.requests(fixture) |> List.last()

    assert {:ok, _} =
             Incus.call(client, "MigrateStoragePoolVolume", %{"pool" => "source-pool"},
               body: body
             )

    actual = HTTPFixture.requests(fixture) |> List.last()
    assert actual.target == expected.target
    assert Jason.decode!(actual.body) == Jason.decode!(expected.body)

    assert URI.parse(actual.target).path ==
             "/1.0/storage-pools/source-pool/volumes/custom/parent/snapshots/snapshot"

    assert {:error, %Error{kind: :invalid_copy_options}} =
             Copy.instance(client, client, %{"name" => "fixture"}, mode: :unknown)

    assert {:error, %Error{kind: :invalid_copy_model}} = Copy.instance(client, client, nil)
    other_project = Incus.project(client, "source")

    assert {:ok, _} =
             Copy.instance(client, other_project, %{"name" => "fixture", "type" => "container"},
               name: "cross-project"
             )

    request = HTTPFixture.requests(fixture) |> List.last()
    assert Jason.decode!(request.body)["source"]["project"] == "source"
    assert URI.decode_query(URI.parse(request.target).query)["project"] == "fixture"
  end

  defp subset?(actual, expected) when is_map(actual) and is_map(expected),
    do:
      Enum.all?(actual, fn {key, value} ->
        Map.has_key?(expected, key) and subset?(value, expected[key])
      end)

  defp subset?(actual, expected), do: actual == expected
end
