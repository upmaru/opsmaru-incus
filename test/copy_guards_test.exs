defmodule Opsmaru.Incus.CopyGuardsTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Copy, Error, Server}
  alias Opsmaru.TestSupport.HTTPFixture
  @driver Path.expand("../../.integration/incus-copy-guards", __DIR__)

  setup_all do
    {out, code} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./copyguards"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert code == 0, out
    :ok
  end

  test "copy option extension preflight agrees with the official helper before any mutation" do
    root = Path.join(System.tmp_dir!(), "op-copy-guards-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for {option, extension, source_extensions, target_extensions} <- [
          {:allow_inconsistent, "instance_allow_inconsistent_copy",
           ["instance_allow_inconsistent_copy"], []},
          {:instance_only, "container_only_migration", ["container_only_migration"], []},
          {:instance_only, "container_only_migration", [], ["container_only_migration"]},
          {:refresh, "container_incremental_copy", ["container_incremental_copy"], []},
          {:refresh, "container_incremental_copy", [], ["container_incremental_copy"]},
          {:refresh_exclude_older, "custom_volume_refresh_exclude_older_snapshots", [],
           ["custom_volume_refresh_exclude_older_snapshots"]},
          {:mode, "container_push", ["container_push"], []},
          {:mode, "container_push_target", ["container_push"], ["container_push"]}
        ] do
      fixture = fixture(root, target_extensions)
      client = bound(fixture, target_extensions)
      source = %{client | server: %Server{api_extensions: source_extensions, environment: %{}}}
      value = if option == :mode, do: :push, else: true

      native_key =
        %{
          allow_inconsistent: "AllowInconsistent",
          instance_only: "InstanceOnly",
          refresh: "Refresh",
          refresh_exclude_older: "RefreshExcludeOlder",
          mode: "Mode"
        }[option]

      native_value = if option == :mode, do: "push", else: true

      input =
        Jason.encode!(%{
          socket: client.connection.address,
          source_extensions: source_extensions,
          options: %{native_key => native_value}
        })

      assert official(input)["error"] =~ extension

      assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
               Copy.instance(client, source, %{"name" => "fixture", "type" => "container"}, [
                 {option, value}
               ])

      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "POST"))
    end
  end

  test "allow inconsistent requires the target capability, not the source capability" do
    root = Path.join(System.tmp_dir!(), "op-copy-allow-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    extension = "instance_allow_inconsistent_copy"
    fixture = fixture(root, [extension])
    target = bound(fixture, [extension])
    source = %{target | server: %Server{api_extensions: [], environment: %{}}}

    assert official(
             Jason.encode!(%{
               socket: target.connection.address,
               source_extensions: [],
               options: %{AllowInconsistent: true}
             })
           )["accepted"] == true

    expected = HTTPFixture.requests(fixture) |> List.last()

    assert {:ok, %{mode: :local}} =
             Copy.instance(target, source, %{"name" => "fixture", "type" => "container"},
               allow_inconsistent: true
             )

    request = HTTPFixture.requests(fixture) |> List.last()
    assert request.target == expected.target
    assert Jason.decode!(expected.body)["source"]["allow_inconsistent"] == true
    assert Jason.decode!(request.body)["source"]["allow_inconsistent"] == true
  end

  test "each copy helper rejects options absent from its native argument type before I/O" do
    socket = Path.join(System.tmp_dir!(), "op-copy-never-#{System.unique_integer([:positive])}")
    refute File.exists?(socket)
    connection = Connection.unix!(socket, owner: :fixture)

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: [], environment: %{}}
    }

    for opts <- [[volume_only: true], %{live: true}, [unknown: false]] do
      assert {:error, %Error{kind: :invalid_copy_options}} =
               Copy.instance(client, client, %{"name" => "fixture"}, opts)
    end

    for option <- [
          :instance_only,
          :refresh,
          :refresh_exclude_older,
          :allow_inconsistent,
          :volume_only
        ] do
      assert {:error, %Error{kind: :invalid_copy_options}} =
               Copy.snapshot(client, client, "parent", %{"name" => "snapshot"}, [{option, true}])
    end

    for option <- [:live, :instance_only, :allow_inconsistent] do
      assert {:error, %Error{kind: :invalid_copy_options}} =
               Copy.volume(client, client, "pool", "source-pool", %{"name" => "volume"}, [
                 {option, true}
               ])
    end
  end

  defp official(input) do
    # Feed the unchanged helper through a shell-free fixture process.
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, input <> "\n")
    assert_receive {^port, {:data, out}}, 5_000
    assert_receive {^port, {:exit_status, 0}}, 5_000
    Jason.decode!(out)
  end

  defp fixture(root, extensions) do
    start_supervised!(
      {HTTPFixture,
       transport: :gen_tcp,
       path: Path.join(root, "s#{System.unique_integer([:positive])}"),
       handler: fn request ->
         if URI.parse(request.target).path == "/1.0",
           do: %{
             status: 200,
             body: %{
               type: "sync",
               metadata: %{api_version: "1.0", api_extensions: extensions, environment: %{}}
             }
           },
           else: %{
             status: 202,
             body: %{
               type: "async",
               operation: "/1.0/operations/copy",
               metadata: %{id: "copy", status_code: 103}
             }
           }
       end},
      id: make_ref()
    )
  end

  defp bound(fixture, extensions),
    do: %Incus{
      connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: extensions, environment: %{}}
    }
end
