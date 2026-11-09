defmodule Opsmaru.Incus.OperationsInspectionTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Operations
  alias Opsmaru.Incus.Operations.Schema
  alias Opsmaru.TestSupport.{OperationsFixture, OperationsHost}
  import OperationsFixture, only: [sync: 1, sync: 2, native_error: 2]

  @container %{
    "name" => "web",
    "type" => "container",
    "status" => "Running",
    "status_code" => 103,
    "config" => %{"image.os" => "Ubuntu"},
    "devices" => %{},
    "profiles" => ["default"],
    "project" => "default",
    "unknown_future_field" => %{"kept" => true}
  }
  @vm %{
    "name" => "db",
    "type" => "virtual-machine",
    "status" => "Stopped",
    "status_code" => 102,
    "config" => %{"limits.memory" => "4GiB", "security.secureboot" => "false"},
    "devices" => %{
      "root" => %{"type" => "disk", "pool" => "default", "path" => "/", "size" => "20GiB"}
    },
    "profiles" => ["default"],
    "project" => "default"
  }
  @vm_state %{
    "status" => "Running",
    "status_code" => 103,
    "cpu" => %{"usage" => 0},
    "memory" => %{"usage" => 1024, "total" => 4_294_967_296},
    "network" => nil,
    "pid" => 4242,
    "processes" => -1
  }

  # {operation, input, native path and query, native metadata}
  @reads [
    {"incus_instance_list", %{}, "/1.0/instances?recursion=1", [@container, @vm]},
    {"incus_instance_list", %{"type" => "virtual-machine"},
     "/1.0/instances?instance-type=virtual-machine&recursion=1", [@vm]},
    {"incus_instance_get", %{"name" => "db"}, "/1.0/instances/db", @vm},
    {"incus_instance_state_get", %{"name" => "db"}, "/1.0/instances/db/state", @vm_state},
    {"incus_instance_snapshot_list", %{"instance" => "db"},
     "/1.0/instances/db/snapshots?recursion=1", [%{"name" => "s1", "stateful" => false}]},
    {"incus_instance_snapshot_get", %{"instance" => "db", "name" => "s1"},
     "/1.0/instances/db/snapshots/s1", %{"name" => "s1", "stateful" => false}},
    {"incus_image_list", %{}, "/1.0/images?recursion=1",
     [%{"fingerprint" => String.duplicate("a", 64), "type" => "virtual-machine"}]},
    {"incus_image_get", %{"fingerprint" => "abc"}, "/1.0/images/abc",
     %{"fingerprint" => String.duplicate("a", 64)}},
    {"incus_image_alias_list", %{}, "/1.0/images/aliases?recursion=1",
     [%{"name" => "ubuntu", "target" => "abc"}]},
    {"incus_project_list", %{}, "/1.0/projects?recursion=1",
     [%{"name" => "default", "config" => %{}}]},
    {"incus_project_get", %{"name" => "default"}, "/1.0/projects/default",
     %{"name" => "default"}},
    {"incus_profile_list", %{}, "/1.0/profiles?recursion=1", [%{"name" => "default"}]},
    {"incus_profile_get", %{"name" => "default"}, "/1.0/profiles/default",
     %{"name" => "default"}},
    {"incus_network_list", %{}, "/1.0/networks?recursion=1",
     [%{"name" => "incusbr0", "managed" => true}]},
    {"incus_network_get", %{"name" => "incusbr0"}, "/1.0/networks/incusbr0",
     %{"name" => "incusbr0"}},
    {"incus_storage_pool_list", %{}, "/1.0/storage-pools?recursion=1",
     [%{"name" => "default", "driver" => "dir"}]},
    {"incus_storage_pool_get", %{"name" => "default"}, "/1.0/storage-pools/default",
     %{"name" => "default"}},
    {"incus_storage_volume_list", %{"pool" => "default"},
     "/1.0/storage-pools/default/volumes?recursion=1",
     [%{"name" => "data", "type" => "custom"}, %{"name" => "db", "type" => "virtual-machine"}]},
    {"incus_storage_volume_get",
     %{"pool" => "default", "type" => "virtual-machine", "name" => "db"},
     "/1.0/storage-pools/default/volumes/virtual-machine/db",
     %{"name" => "db", "type" => "virtual-machine"}},
    {"incus_operation_list", %{}, "/1.0/operations?recursion=1",
     %{"running" => [OperationsFixture.operation("01234567-89ab-cdef-0123-456789abcdef", 103)]}}
  ]

  setup do
    root = OperationsFixture.root()
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp start(root, transport, routes, opts \\ []) do
    fixture = OperationsFixture.start(root, transport, routes, opts)
    {fixture, %{binding: {fixture.connection, fixture.context}}}
  end

  defp run(name, input, caller),
    do: Operations.run(name, input, host: OperationsHost, caller: caller, scopes: ["incus.read"])

  for transport <- [:gen_tcp, :ssl] do
    test "every inspection returns native data unchanged over #{transport}", %{root: root} do
      routes = Map.new(@reads, fn {_, _, target, metadata} -> {target, metadata} end)

      {fixture, caller} =
        start(root, unquote(transport), fn request ->
          case Map.fetch(routes, request.target) do
            {:ok, metadata} -> sync(metadata, %{"ETag" => "\"etag-1\""})
            :error -> :next
          end
        end)

      for {name, input, target, metadata} <- @reads do
        assert {:ok, result} = run(name, input, caller), name
        {:ok, descriptor} = Operations.fetch(name)
        assert :ok = Schema.validate(descriptor.output_schema, result), name

        case metadata do
          list when is_list(list) ->
            assert result == %{"items" => list, "count" => length(list), "truncated" => false}

          %{"running" => list} ->
            assert result["items"] == list

          item ->
            assert result["item"] == item
        end

        assert List.last(OperationsFixture.requests(fixture)).target == target
      end

      assert {:ok, %{"etag" => "\"etag-1\""}} =
               run("incus_instance_get", %{"name" => "db"}, caller)

      assert Enum.all?(OperationsFixture.requests(fixture), &(&1.method == "GET"))
    end
  end

  test "VM-shaped instances, state and volumes pass through unchanged", %{root: root} do
    {_fixture, caller} =
      start(root, :gen_tcp, fn request ->
        case request.target do
          "/1.0/instances?recursion=1" -> sync([@container, @vm])
          "/1.0/instances/db/state" -> sync(@vm_state)
          _ -> :next
        end
      end)

    assert {:ok, %{"items" => [container, vm]}} = run("incus_instance_list", %{}, caller)
    assert container["unknown_future_field"] == %{"kept" => true}
    assert vm == @vm

    assert {:ok, %{"item" => @vm_state}} =
             run("incus_instance_state_get", %{"name" => "db"}, caller)
  end

  test "lists are bounded by limit and keep the native total", %{root: root} do
    items = for n <- 1..7, do: %{"name" => "i#{n}"}

    {_fixture, caller} =
      start(root, :gen_tcp, fn request ->
        if request.target == "/1.0/profiles?recursion=1", do: sync(items), else: :next
      end)

    assert {:ok,
            %{
              "items" => [%{"name" => "i1"}, %{"name" => "i2"}],
              "count" => 7,
              "truncated" => true
            }} =
             run("incus_profile_list", %{"limit" => 2}, caller)

    assert {:ok, %{"items" => ^items, "truncated" => false}} =
             run("incus_profile_list", %{}, caller)

    assert {:error, %{"kind" => "invalid_input"}} =
             run("incus_profile_list", %{"limit" => 501}, caller)

    assert {:error, %{"kind" => "invalid_input"}} =
             run("incus_profile_list", %{"limit" => 0}, caller)
  end

  test "output beyond 256 KiB is truncated explicitly, or fails for a single oversized item", %{
    root: root
  } do
    big = String.duplicate("x", 60_000)
    items = for n <- 1..10, do: %{"name" => "p#{n}", "description" => big}
    huge = %{"name" => "huge", "description" => String.duplicate("y", 300_000)}

    {_fixture, caller} =
      start(root, :gen_tcp, fn request ->
        case request.target do
          "/1.0/profiles?recursion=1" -> sync(items)
          "/1.0/networks?recursion=1" -> sync([huge, %{"name" => "small"}])
          "/1.0/profiles/huge" -> sync(huge)
          _ -> :next
        end
      end)

    assert {:ok, %{"items" => kept, "count" => 10, "truncated" => true} = result} =
             run("incus_profile_list", %{}, caller)

    assert length(kept) in 1..4 and kept == Enum.take(items, length(kept))
    assert byte_size(Jason.encode!(result)) <= 262_144

    assert {:error, %{"kind" => "output_limit"}} = run("incus_network_list", %{}, caller)

    assert {:error, %{"kind" => "output_limit"}} =
             run("incus_profile_get", %{"name" => "huge"}, caller)
  end

  test "native errors keep status, code and message", %{root: root} do
    {_fixture, caller} =
      start(root, :gen_tcp, fn request ->
        if request.target == "/1.0/instances/ghost",
          do: native_error(404, "Instance not found"),
          else: :next
      end)

    assert {:error,
            %{
              "kind" => "native",
              "http_status" => 404,
              "error_code" => 404,
              "message" => "Instance not found"
            }} =
             run("incus_instance_get", %{"name" => "ghost"}, caller)
  end

  test "server inspection rediscovers instead of reporting a cached record", %{root: root} do
    {fixture, caller} = start(root, :gen_tcp, fn _ -> :next end)

    assert {:ok,
            %{"item" => %{"api_version" => "1.0", "environment" => %{"server_name" => "fixture"}}}} =
             run("incus_server_get", %{}, caller)

    assert [%{target: "/1.0"}, %{target: "/1.0"}] = OperationsFixture.requests(fixture)
  end

  test "project selection reaches the native query for inspection", %{root: root} do
    {fixture, caller} =
      start(root, :gen_tcp, fn request ->
        if OperationsFixture.path(request) == "/1.0/images", do: sync([]), else: :next
      end)

    assert {:ok, _} = run("incus_image_list", %{"project" => "team a"}, caller)

    assert List.last(OperationsFixture.requests(fixture)).target ==
             "/1.0/images?recursion=1&project=team+a"
  end
end
