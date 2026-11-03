defmodule Opsmaru.Incus.Operations.Instances do
  @moduledoc false
  # Instance, snapshot and image mutations and deletions. Create/update input
  # is curated; restricted config keys and devices need host approval.
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Operations.{Descriptor, Mutation, Result}
  import Opsmaru.Incus.Operations.Fragments

  @restricted_prefixes ["raw.", "volatile.", "security.idmap.", "security.syscalls."]
  @restricted_keys ["security.privileged", "linux.kernel_modules"]
  @disk_keys ~w(type pool source path size readonly boot.priority limits.read limits.write limits.max)
  @nic_keys ~w(type network name hwaddr ipv4.address ipv6.address mtu boot.priority
               security.mac_filtering security.ipv4_filtering security.ipv6_filtering)
  @remote_protocols ["simplestreams", "incus", "oci"]

  def descriptors do
    [
      create(),
      update(),
      state_update(),
      snapshot_create(),
      snapshot_restore(),
      delete(
        "incus_instance_delete",
        "Delete instance",
        "Delete a stopped instance and its snapshots. Requires `confirm` to repeat the instance name.",
        "DeleteInstance",
        %{"name" => name("Instance name.")},
        &%{"name" => &1["name"]},
        & &1["name"],
        "the instance name"
      ),
      delete(
        "incus_instance_snapshot_delete",
        "Delete instance snapshot",
        "Delete one instance snapshot. Requires `confirm` to repeat `<instance>/<snapshot>`.",
        "DeleteInstanceSnapshot",
        %{"instance" => name("Instance name."), "name" => name("Snapshot name.")},
        &%{"instance_name" => &1["instance"], "name" => &1["name"]},
        &(&1["instance"] <> "/" <> &1["name"]),
        "`<instance>/<snapshot>`"
      ),
      delete(
        "incus_image_delete",
        "Delete image",
        "Delete a local image by its full fingerprint. Requires `confirm` to repeat the fingerprint.",
        "DeleteImage",
        %{
          "fingerprint" => %{
            "type" => "string",
            "pattern" => "^[0-9a-f]{64}$",
            "description" => "Full 64-character image fingerprint."
          }
        },
        &%{"fingerprint" => &1["fingerprint"]},
        & &1["fingerprint"],
        "the full fingerprint"
      )
    ]
  end

  defp create do
    image =
      Map.merge(
        object(%{
          "alias" => line(255, "Image alias."),
          "fingerprint" => fingerprint("Image fingerprint or unique prefix."),
          "remote" =>
            name("Host-approved image remote name; omit for a local image. Never a URL.")
        }),
        %{"oneOf" => [%{"required" => ["alias"]}, %{"required" => ["fingerprint"]}]}
      )

    %Descriptor{
      name: "incus_instance_create",
      title: "Create instance",
      description:
        "Create a container or VM from an image, optionally starting it, and wait boundedly for the native operation.",
      scope: "incus.write",
      input_schema:
        object(
          Map.merge(instance_fields(), %{
            "project" => project(),
            "name" => name("New instance name."),
            "type" => %{
              "type" => "string",
              "enum" => ["container", "virtual-machine"],
              "description" => "Instance type (default container)."
            },
            "image" => image,
            "start" => %{"type" => "boolean", "description" => "Start after creation."},
            "wait_seconds" => wait_seconds()
          }),
          ["name", "image"]
        ),
      output_schema: mutation_output(),
      bounds: mutation_bounds(),
      requires: ["CreateInstance", "GetOperationWait"],
      restricted: &restricted/1,
      resolve: &resolve_remote/2,
      run: fn client, input, env ->
        body =
          input
          |> Map.take(["name", "start" | Map.keys(instance_fields())])
          |> Map.put("type", Map.get(input, "type", "container"))
          |> Map.put("source", source(input))

        Mutation.submit(client, "CreateInstance", %{}, body, input, env)
      end
    }
  end

  defp update do
    %Descriptor{
      name: "incus_instance_update",
      title: "Update instance",
      description:
        "Change an instance's config, devices, profiles, description or ephemeral flag with a conditional PATCH of only the given fields. Without `etag` the current ETag is read first.",
      scope: "incus.write",
      input_schema:
        object(
          Map.merge(instance_fields(), %{
            "project" => project(),
            "name" => name("Instance name."),
            "etag" =>
              line(1024, "ETag from incus_instance_get; a concurrent change fails natively.")
          }),
          ["name"]
        ),
      output_schema:
        mutation_output(%{
          "etag_source" => %{
            "type" => "string",
            "enum" => ["input", "read"],
            "description" => "Whether the PATCH used the given ETag or one read just before it."
          }
        }),
      bounds: mutation_bounds(),
      requires: ["PatchInstance", "GetInstance"],
      check: fn input ->
        if Map.take(input, Map.keys(instance_fields())) == %{},
          do: {:error, "", "must set at least one instance field"},
          else: :ok
      end,
      restricted: &restricted/1,
      run: fn client, input, _env ->
        body = Map.take(input, Map.keys(instance_fields()))
        args = %{"name" => input["name"]}

        with {:ok, etag, source} <- etag(client, input),
             {:ok, _} <- Incus.call(client, "PatchInstance", args, body: body, etag: etag) do
          {:ok, Map.put(Mutation.completed_sync(), "etag_source", source)}
        else
          {:error, %Incus.Error{kind: :uncertain} = error} ->
            {:ok, Map.put(Mutation.uncertain(error), "etag_source", etag_source(input))}

          other ->
            other
        end
      end
    }
  end

  defp etag(_client, %{"etag" => etag}), do: {:ok, etag, "input"}

  defp etag(client, input) do
    case Incus.call(client, "GetInstance", %{"name" => input["name"]}) do
      {:ok, %{etag: etag}} when is_binary(etag) and byte_size(etag) in 1..1024 ->
        {:ok, etag, "read"}

      {:ok, _} ->
        Result.error("etag_unavailable", "the server returned no ETag for this instance")

      error ->
        error
    end
  end

  defp etag_source(input), do: if(Map.has_key?(input, "etag"), do: "input", else: "read")

  defp state_update do
    %Descriptor{
      name: "incus_instance_state_update",
      title: "Change instance state",
      description:
        "Start, stop, restart, freeze or unfreeze an instance and wait boundedly for the native operation.",
      scope: "incus.write",
      input_schema:
        object(
          %{
            "project" => project(),
            "name" => name("Instance name."),
            "action" => %{
              "type" => "string",
              "enum" => ["start", "stop", "restart", "freeze", "unfreeze"]
            },
            "force" => %{"type" => "boolean", "description" => "Force stop or restart."},
            "stateful" => %{
              "type" => "boolean",
              "description" => "Save or restore runtime state."
            },
            "timeout" => %{
              "type" => "integer",
              "minimum" => -1,
              "maximum" => 3600,
              "default" => -1,
              "description" =>
                "Native clean-shutdown timeout in seconds for stop/restart; -1 (default) waits for the guest."
            },
            "wait_seconds" => wait_seconds()
          },
          ["name", "action"]
        ),
      output_schema: mutation_output(),
      bounds: mutation_bounds(),
      requires: ["UpdateInstanceState", "GetOperationWait"],
      run: fn client, input, env ->
        body = %{
          "action" => input["action"],
          "timeout" => Map.get(input, "timeout", -1),
          "force" => Map.get(input, "force", false),
          "stateful" => Map.get(input, "stateful", false)
        }

        Mutation.submit(
          client,
          "UpdateInstanceState",
          %{"name" => input["name"]},
          body,
          input,
          env
        )
      end
    }
  end

  defp snapshot_create do
    %Descriptor{
      name: "incus_instance_snapshot_create",
      title: "Create instance snapshot",
      description:
        "Snapshot an instance (Incus names it when `name` is omitted) and wait boundedly for the native operation.",
      scope: "incus.write",
      input_schema:
        object(
          %{
            "project" => project(),
            "instance" => name("Instance name."),
            "name" => name("Snapshot name."),
            "stateful" => %{"type" => "boolean", "description" => "Include runtime state."},
            "wait_seconds" => wait_seconds()
          },
          ["instance"]
        ),
      output_schema: mutation_output(),
      bounds: mutation_bounds(),
      requires: ["CreateInstanceSnapshot", "GetOperationWait"],
      run: fn client, input, env ->
        body = %{
          "name" => Map.get(input, "name", ""),
          "stateful" => Map.get(input, "stateful", false)
        }

        Mutation.submit(
          client,
          "CreateInstanceSnapshot",
          %{"instance_name" => input["instance"]},
          body,
          input,
          env
        )
      end
    }
  end

  defp snapshot_restore do
    %Descriptor{
      name: "incus_instance_snapshot_restore",
      title: "Restore instance snapshot",
      description:
        "Restore an instance to a snapshot, discarding its current state. Requires `confirm` to repeat `<instance>/<snapshot>`.",
      scope: "incus.delete",
      destructive: true,
      confirmation: %{"field" => "confirm", "value" => "`<instance>/<snapshot>`"},
      confirm: &(&1["instance"] <> "/" <> &1["snapshot"]),
      input_schema:
        object(
          %{
            "project" => project(),
            "instance" => name("Instance name."),
            "snapshot" => name("Snapshot name."),
            "stateful" => %{"type" => "boolean", "description" => "Restore runtime state too."},
            "confirm" => confirm("Repeat `<instance>/<snapshot>` to confirm."),
            "wait_seconds" => wait_seconds()
          },
          ["instance", "snapshot", "confirm"]
        ),
      output_schema: mutation_output(),
      bounds: mutation_bounds(),
      requires: ["UpdateInstance", "GetOperationWait"],
      run: fn client, input, env ->
        body = %{"restore" => input["snapshot"], "stateful" => Map.get(input, "stateful", false)}

        Mutation.submit(
          client,
          "UpdateInstance",
          %{"name" => input["instance"]},
          body,
          input,
          env
        )
      end
    }
  end

  defp delete(name, title, description, method, props, args, confirm, what) do
    %Descriptor{
      name: name,
      title: title,
      description: description,
      scope: "incus.delete",
      destructive: true,
      confirmation: %{"field" => "confirm", "value" => what},
      confirm: confirm,
      input_schema:
        object(
          Map.merge(props, %{
            "project" => project(),
            "confirm" => confirm("Repeat #{what} to confirm."),
            "wait_seconds" => wait_seconds()
          }),
          Map.keys(props) ++ ["confirm"]
        ),
      output_schema: mutation_output(),
      bounds: mutation_bounds(),
      requires: [method, "GetOperationWait"],
      run: fn client, input, env ->
        Mutation.submit(client, method, args.(input), nil, input, env)
      end
    }
  end

  defp instance_fields do
    %{
      "config" => %{
        "type" => "object",
        "maxProperties" => 256,
        "propertyNames" => line(512, "Config key."),
        "additionalProperties" => %{"type" => "string", "maxLength" => 16_384},
        "description" =>
          "Native config keys. raw.*, volatile.*, security.privileged and similar keys need host approval."
      },
      "devices" => %{
        "type" => "object",
        "maxProperties" => 64,
        "propertyNames" => line(255, "Device name."),
        "additionalProperties" => %{
          "type" => "object",
          "maxProperties" => 64,
          "propertyNames" => line(255, "Device key."),
          "additionalProperties" => %{"type" => "string", "maxLength" => 4096}
        },
        "description" =>
          "Native devices. Without host approval only a pool-backed disk without a host path and a nic on a managed network are allowed."
      },
      "profiles" => %{
        "type" => "array",
        "maxItems" => 64,
        "items" => name("Profile name."),
        "description" => "Profiles, in order (native default when omitted)."
      },
      "description" => text(4096, "Instance description."),
      "ephemeral" => %{"type" => "boolean", "description" => "Delete the instance when it stops."}
    }
  end

  @doc false
  def restricted(input) do
    config =
      for {key, _} <- Map.get(input, "config", %{}),
          String.starts_with?(key, @restricted_prefixes) or key in @restricted_keys,
          do: {:config, key}

    devices =
      for {name, device} <- Map.get(input, "devices", %{}),
          not allowed_device?(device),
          do: {:device, name}

    Enum.sort(config) ++ Enum.sort(devices)
  end

  defp allowed_device?(%{"type" => "disk", "pool" => pool} = device) when is_binary(pool),
    do:
      Map.keys(device) -- @disk_keys == [] and
        not String.starts_with?(Map.get(device, "source", ""), "/")

  defp allowed_device?(%{"type" => "nic", "network" => network} = device) when is_binary(network),
    do: Map.keys(device) -- @nic_keys == []

  defp allowed_device?(_), do: false

  # The remote is a host-approved name; its URL never comes from input.
  defp resolve_remote(%{"image" => %{"remote" => remote}} = input, callback) do
    case callback.(:image_remote, [remote]) do
      {:ok, {:ok, %{"server" => "https://" <> _ = server, "protocol" => protocol}}}
      when protocol in @remote_protocols ->
        {:ok, Map.put(input, :remote, %{"server" => server, "protocol" => protocol})}

      _ ->
        Result.error("image_remote_unavailable", "the host does not provide this image remote")
    end
  end

  defp resolve_remote(input, _), do: {:ok, input}

  defp source(input) do
    image = input["image"]
    base = %{"type" => "image"} |> Map.merge(Map.take(image, ["alias", "fingerprint"]))

    case input do
      %{remote: remote} -> base |> Map.merge(remote) |> Map.put("mode", "pull")
      _ -> base
    end
  end
end
