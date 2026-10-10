defmodule Opsmaru.Incus.Copy do
  @moduledoc """
  Native instance/snapshot/volume copy preparation over explicit bound clients.
  Returns accepted local or paired migration handles, never completed workloads.
  No address fallback, automatic relay activation, cancellation or data deletion.
  """
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Error, Migration, Model, Operation}

  def instance(target, source, instance, opts \\ []) do
    with :ok <- authorize(target, source, opts),
         {:ok, instance} <- model("Instance", instance),
         :ok <- instance_extensions(target, source, opts) do
      data = instance.data
      live = opts[:live] == true and data["status_code"] == 103

      fields = %{
        "base-image" => get_in(data, ["config", "volatile.base_image"]) || "",
        "live" => live,
        "instance_only" => opts[:instance_only] == true,
        "refresh" => opts[:refresh] == true,
        "refresh_exclude_older" => opts[:refresh_exclude_older] == true,
        "allow_inconsistent" => opts[:allow_inconsistent] == true
      }

      body =
        Map.take(data, [
          "architecture",
          "config",
          "devices",
          "ephemeral",
          "profiles",
          "stateful",
          "description",
          "type"
        ])

      body =
        Map.merge(body, %{
          "name" => opts[:name] || data["name"],
          "source" => source_fields(:instance, fields)
        })

      request = %{
        "migration" => true,
        "live" => live,
        "instance_only" => opts[:instance_only] == true,
        "allow_inconsistent" => opts[:allow_inconsistent] == true
      }

      request =
        if Incus.has_extension?(source, "dependent"),
          do: Map.put(request, "devices", data["devices"]),
          else: request

      dispatch(
        target,
        source,
        {"MigrateInstance", %{"name" => data["name"]}, request},
        {"CreateInstance", %{}, body},
        data["location"],
        data["name"],
        :instance,
        opts
      )
    else
      {:error, error} -> error(error)
    end
  end

  def snapshot(target, source, parent, snapshot, opts \\ []) do
    with :ok <- authorize(target, source, opts),
         {:ok, snapshot} <- model("InstanceSnapshot", snapshot),
         :ok <- mode_extensions(target, source, opts),
         :ok <-
           required(
             target,
             snapshot.data["stateful"] == true and opts[:live] == true,
             "container_snapshot_stateful_migration"
           ),
         {:ok, parent_response} <- Incus.call(source, "GetInstance", %{"name" => parent}) do
      data = snapshot.data
      name = String.split(data["name"], "/") |> List.last()
      live = data["stateful"] == true and opts[:live] == true
      body = Map.take(data, ["architecture", "config", "devices", "ephemeral", "profiles"])

      body =
        Map.merge(body, %{
          "name" => opts[:name] || parent,
          "stateful" => live,
          "source" => %{"base-image" => get_in(data, ["config", "volatile.base_image"]) || ""}
        })

      body =
        if Incus.has_extension?(source, "virtual-machines"),
          do: Map.put(body, "type", parent_response.metadata.data["type"]),
          else: body

      dispatch(
        target,
        source,
        {"MigrateInstanceSnapshot", %{"instance_name" => parent, "name" => name},
         %{"migration" => true, "name" => opts[:name] || "", "live" => live}},
        {"CreateInstance", %{}, body},
        parent_response.metadata.data["location"],
        parent <> "/" <> name,
        :instance,
        opts
      )
    else
      {:error, error} -> error(error)
    end
  end

  def volume(target, source, pool, source_pool, volume, opts \\ []) do
    with :ok <- authorize(target, source, opts),
         {:ok, volume} <- model("StorageVolume", volume),
         :ok <- Incus.require_extension(target, "storage_api_local_volume_handling"),
         :ok <- required(target, opts[:volume_only] == true, "storage_api_volume_snapshots"),
         :ok <- required(target, opts[:refresh] == true, "custom_volume_refresh"),
         :ok <-
           required(
             target,
             opts[:refresh_exclude_older] == true,
             "custom_volume_refresh_exclude_older_snapshots"
           ) do
      data = volume.data
      body = Map.take(data, ["type", "config", "description", "content_type"])

      body =
        Map.merge(body, %{
          "name" => opts[:name] || data["name"],
          "source" => %{
            "name" => data["name"],
            "type" => "copy",
            "pool" => source_pool,
            "volume_only" => opts[:volume_only] == true,
            "refresh" => opts[:refresh] == true,
            "refresh_exclude_older" => opts[:refresh_exclude_older] == true
          }
        })

      dispatch(
        target,
        source,
        {"MigrateStoragePoolVolume", %{"pool" => source_pool},
         %{
           "migration" => true,
           "name" => data["name"],
           "pool" => source_pool,
           "volume_only" => opts[:volume_only] == true
         }},
        {"CreateStoragePoolVolumeFromMigration", %{"pool" => pool}, body},
        data["location"],
        data["name"],
        :volume,
        opts
      )
    else
      {:error, error} -> error(error)
    end
  end

  defp dispatch(
         target,
         source,
         source_request,
         {method, args, body},
         location,
         name,
         kind,
         opts
       ) do
    body = Map.put(body, "source", source_fields(kind, body["source"]))
    target_request = {method, args, body}

    local =
      target.connection.transport == source.connection.transport and
        target.connection.address == source.connection.address

    internal =
      Incus.has_extension?(
        target,
        if(kind == :volume,
          do: "cluster_internal_custom_volume_copy",
          else: "cluster_internal_copy"
        )
      )

    clustered = (target.server.environment || %{})["server_clustered"] == true

    colocated =
      location == target.connection.member or
        (kind == :volume and location == "none" and is_nil(target.connection.member))

    if local and (internal or colocated or (kind == :instance and not clustered)) do
      different_project =
        (source.connection.project || "default") != (target.connection.project || "default")

      with :ok <-
             required(
               target,
               different_project,
               if(kind == :volume, do: "storage_api_project", else: "container_copy_project")
             ) do
        fields =
          if kind == :instance,
            do: %{"type" => "copy", "source" => name},
            else: %{"type" => "copy"}

        fields =
          if different_project,
            do: Map.put(fields, "project", source.connection.project || "default"),
            else: fields

        fields =
          if kind == :volume and internal,
            do: Map.put(fields, "location", source.connection.member || ""),
            else: fields

        body = Map.put(body, "source", Map.merge(body["source"], fields))

        with {:ok, response} <- Incus.call(target, method, args, body: body),
             {:ok, operation} <- Operation.from_response(target, response),
             do: {:ok, %Migration{mode: :local, target: operation}}
      end
    else
      with :ok <- required(target, kind == :volume, "storage_api_remote_volume_handling") do
        Migration.negotiate(source, target, source_request, target_request,
          mode: opts[:mode] || :pull,
          approved_origin: opts[:approved_origin]
        )
      end
    end
  end

  defp authorize(target, source, opts) do
    with :ok <- Context.authorize(target.context, target.connection),
         :ok <- Context.authorize(source.context, source.connection),
         true <- opts[:mode] in [nil, :pull, :push, :relay],
         true <-
           Enum.all?(
             [
               :live,
               :instance_only,
               :refresh,
               :refresh_exclude_older,
               :allow_inconsistent,
               :volume_only
             ],
             &(opts[&1] in [nil, true, false])
           ),
         true <-
           is_nil(opts[:name]) or (is_binary(opts[:name]) and byte_size(opts[:name]) in 1..1024),
         true <-
           Keyword.keys(opts) --
             [
               :name,
               :mode,
               :approved_origin,
               :live,
               :instance_only,
               :refresh,
               :refresh_exclude_older,
               :allow_inconsistent,
               :volume_only
             ] == [],
         do: :ok,
         else: (
           {:error, error} -> {:error, error}
           _ -> {:error, :invalid_copy_options}
         )
  end

  defp instance_extensions(target, source, opts) do
    with :ok <- mode_extensions(target, source, opts),
         :ok <- required(target, opts[:instance_only] == true, "container_only_migration"),
         :ok <- required(source, opts[:instance_only] == true, "container_only_migration"),
         :ok <- required(target, opts[:refresh] == true, "container_incremental_copy"),
         :ok <- required(source, opts[:refresh] == true, "container_incremental_copy"),
         :ok <-
           required(
             source,
             opts[:refresh_exclude_older] == true,
             "custom_volume_refresh_exclude_older_snapshots"
           ),
         :ok <-
           required(target, opts[:allow_inconsistent] == true, "instance_allow_inconsistent_copy"),
         do: :ok
  end

  defp mode_extensions(target, source, opts) do
    with :ok <- required(target, opts[:mode] in [:push, :relay], "container_push"),
         :ok <- required(source, opts[:mode] in [:push, :relay], "container_push"),
         :ok <- required(source, opts[:mode] == :push, "container_push_target"),
         do: :ok
  end

  defp source_fields(:instance, fields) do
    fields
    |> Map.put_new("certificate", "")
    |> Map.put_new("allow_inconsistent", false)
    |> Map.reject(fn {key, value} ->
      key not in ["type", "certificate", "allow_inconsistent"] and
        value in [nil, "", false, 0, [], %{}]
    end)
  end

  defp source_fields(:volume, fields),
    do: fields |> Map.put_new("certificate", "") |> Map.put_new("location", "")

  defp model(type, value) do
    with {:ok, model} <- Model.decode(type, Model.encode(value)),
         true <-
           is_map(model.data) and is_binary(model.data["name"]) and
             byte_size(model.data["name"]) in 1..1024,
         do: {:ok, model},
         else: (_ -> {:error, :invalid_copy_model})
  end

  defp required(_, false, _), do: :ok
  defp required(client, true, extension), do: Incus.require_extension(client, extension)
  defp error(%Error{} = error), do: {:error, error}
  defp error(kind), do: {:error, %Error{kind: kind}}
end
