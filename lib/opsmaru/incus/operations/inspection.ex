defmodule Opsmaru.Incus.Operations.Inspection do
  @moduledoc false
  # Read-only operations (scope incus.read). Native data passes through
  # unchanged, including VM-shaped instances; lists keep native order.
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Operations.{Descriptor, Result}
  import Opsmaru.Incus.Operations.Fragments

  def descriptors do
    [
      %Descriptor{
        name: "incus_server_get",
        title: "Get Incus server",
        description:
          "Read the Incus server's native discovery record (API version, extensions, environment) with a fresh request.",
        scope: "incus.read",
        input_schema: object(%{}),
        output_schema: get_output("Native Server record."),
        bounds: get_bounds(),
        requires: ["helper:connect"],
        run: &server/3
      },
      list(
        "incus_instance_list",
        "List instances",
        "instances (containers and VMs)",
        "GetInstances",
        props: %{
          "type" => %{
            "type" => "string",
            "enum" => ["container", "virtual-machine"],
            "description" => "Only list instances of this type."
          }
        },
        args: &%{"instance_type" => Map.get(&1, "type", "")}
      ),
      get(
        "incus_instance_get",
        "Get instance",
        "an instance's native configuration and its ETag",
        "GetInstance",
        props: %{"name" => name("Instance name.")},
        args: &%{"name" => &1["name"]},
        etag: true
      ),
      get(
        "incus_instance_state_get",
        "Get instance state",
        "an instance's runtime state",
        "GetInstanceState",
        props: %{"name" => name("Instance name.")},
        args: &%{"name" => &1["name"]}
      ),
      list(
        "incus_instance_snapshot_list",
        "List instance snapshots",
        "an instance's snapshots",
        "GetInstanceSnapshots",
        props: %{"instance" => name("Instance name.")},
        required: ["instance"],
        args: &%{"instance_name" => &1["instance"]}
      ),
      get(
        "incus_instance_snapshot_get",
        "Get instance snapshot",
        "one instance snapshot",
        "GetInstanceSnapshot",
        props: %{"instance" => name("Instance name."), "name" => name("Snapshot name.")},
        args: &%{"instance_name" => &1["instance"], "name" => &1["name"]}
      ),
      list("incus_image_list", "List images", "local images", "GetImages"),
      get("incus_image_get", "Get image", "one local image", "GetImage",
        props: %{"fingerprint" => fingerprint("Image fingerprint or unique prefix.")},
        args: &%{"fingerprint" => &1["fingerprint"]}
      ),
      list(
        "incus_image_alias_list",
        "List image aliases",
        "local image aliases",
        "GetImageAliases"
      ),
      list("incus_project_list", "List projects", "projects", "GetProjects", project: false),
      get("incus_project_get", "Get project", "one project", "GetProject",
        props: %{"name" => name("Project name.")},
        args: &%{"name" => &1["name"]},
        project: false
      ),
      list("incus_profile_list", "List profiles", "profiles", "GetProfiles"),
      get("incus_profile_get", "Get profile", "one profile", "GetProfile",
        props: %{"name" => name("Profile name.")},
        args: &%{"name" => &1["name"]}
      ),
      list("incus_network_list", "List networks", "networks", "GetNetworks"),
      get("incus_network_get", "Get network", "one network", "GetNetwork",
        props: %{"name" => name("Network name.")},
        args: &%{"name" => &1["name"]}
      ),
      list("incus_storage_pool_list", "List storage pools", "storage pools", "GetStoragePools"),
      get("incus_storage_pool_get", "Get storage pool", "one storage pool", "GetStoragePool",
        props: %{"name" => name("Storage pool name.")},
        args: &%{"name" => &1["name"]}
      ),
      list(
        "incus_storage_volume_list",
        "List storage volumes",
        "a pool's storage volumes",
        "GetStoragePoolVolumes",
        props: %{"pool" => name("Storage pool name.")},
        required: ["pool"],
        args: &%{"pool" => &1["pool"]}
      ),
      get(
        "incus_storage_volume_get",
        "Get storage volume",
        "one storage volume",
        "GetStoragePoolVolume",
        props: %{
          "pool" => name("Storage pool name."),
          "type" => %{
            "type" => "string",
            "enum" => ["custom", "container", "virtual-machine", "image"],
            "description" => "Volume type."
          },
          "name" => name("Volume name.")
        },
        args: &%{"pool" => &1["pool"], "volType" => &1["type"], "name" => &1["name"]}
      ),
      list("incus_operation_list", "List operations", "background operations", "GetOperations")
    ]
  end

  defp list(name, title, what, method, opts \\ []) do
    props = Keyword.get(opts, :props, %{}) |> Map.put("limit", limit()) |> with_project(opts)
    args = Keyword.get(opts, :args, fn _ -> %{} end)

    %Descriptor{
      name: name,
      title: title,
      description: "List #{what}, in native order, up to `limit` items with the native total.",
      scope: "incus.read",
      input_schema: object(props, Keyword.get(opts, :required, [])),
      output_schema: list_output("Native #{method |> String.trim_leading("Get")} item."),
      bounds: list_bounds(),
      requires: [method],
      run: fn client, input, env ->
        with {:ok, response} <- Incus.call(client, method, args.(input)) do
          bounds = env.descriptor.bounds

          Result.list(
            Enum.map(response.metadata, &Result.native/1),
            Map.get(input, "limit", bounds["default_items"]),
            bounds["max_output_bytes"]
          )
        end
      end
    }
  end

  defp get(name, title, what, method, opts) do
    props = Keyword.fetch!(opts, :props) |> with_project(opts)
    args = Keyword.fetch!(opts, :args)
    etag? = Keyword.get(opts, :etag, false)

    output =
      if etag?,
        do:
          object(
            %{
              "item" => native_object("Native #{String.trim_leading(method, "Get")} record."),
              "etag" => %{
                "type" => "string",
                "description" => "Native ETag for a conditional update."
              }
            },
            ["item", "etag"]
          ),
        else: get_output("Native #{String.trim_leading(method, "Get")} record.")

    %Descriptor{
      name: name,
      title: title,
      description: "Read #{what}.",
      scope: "incus.read",
      input_schema: object(props, Map.keys(Keyword.fetch!(opts, :props))),
      output_schema: output,
      bounds: get_bounds(),
      requires: [method],
      run: fn client, input, _env ->
        with {:ok, response} <- Incus.call(client, method, args.(input)) do
          item = %{"item" => Result.native(response)}
          {:ok, if(etag?, do: Map.put(item, "etag", response.etag), else: item)}
        end
      end
    }
  end

  defp with_project(props, opts),
    do:
      if(Keyword.get(opts, :project, true), do: Map.put(props, "project", project()), else: props)

  defp server(client, _input, _env) do
    with {:ok, current} <- Incus.connect(client.connection, client.context),
         do: {:ok, %{"item" => current.server.raw}}
  end
end
