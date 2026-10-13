defmodule Opsmaru.Incus.Copy do
  @moduledoc """
  Native instance/snapshot/volume copy preparation over explicit bound clients.
  Returns accepted local or paired migration handles, never completed workloads.
  No address fallback, automatic relay activation, cancellation or data deletion.
  """
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Error, Migration, Model, NativeInput, Operation}

  @doc "Move/rename a volume within one explicit backend; project is the destination project."
  def move_volume(client, pool, source_pool, volume, opts \\ []) do
    with :ok <- Context.authorize(client.context, client.connection),
         true <- valid_options?(opts, [:name, :project]),
         true <- valid_name?(pool) and valid_name?(source_pool) and valid_name?(opts[:name]),
         true <- is_nil(opts[:project]) or valid_name?(opts[:project]),
         {:ok, volume} <- model("StorageVolume", volume),
         true <- valid_name?(volume.data["type"]),
         :ok <- Incus.require_extension(client, "storage_api_local_volume_handling"),
         :ok <- required(client, not is_nil(opts[:project]), "storage_volume_project_move"),
         {:ok, body} <-
           Model.decode(
             "StorageVolumePost",
             %{
               "name" => opts[:name],
               "pool" => pool,
               "migration" => false,
               "target" => nil,
               "volume_only" => false
             }
             |> then(fn body ->
               if opts[:project], do: Map.put(body, "project", opts[:project]), else: body
             end)
           ),
         path =
           "/1.0/storage-pools/" <>
             escape(source_pool) <>
             "/volumes/" <>
             escape(volume.data["type"]) <> "/" <> escape(volume.data["name"]),
         {:ok, response} <- Incus.raw_query(client, "POST", path, body: body.data),
         {:ok, operation} <- Operation.from_response(client, response) do
      {:ok, %Migration{mode: :local, target: operation}}
    else
      {:error, error} -> error(error)
      _ -> error(:invalid_move_options)
    end
  end

  def instance(target, source, instance, opts \\ []) do
    with :ok <-
           authorize(target, source, opts, [
             :live,
             :instance_only,
             :refresh,
             :refresh_exclude_older,
             :allow_inconsistent
           ]),
         {:ok, instance} <- model("Instance", instance),
         {:ok, writable} <- Model.writable(instance),
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
        Map.merge(writable.data, %{
          "type" => data["type"],
          "name" => name_or(opts, data["name"]),
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
          do: Map.put(request, "Devices", data["devices"]),
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
    with :ok <- authorize(target, source, opts, [:live]),
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
          "name" => name_or(opts, parent),
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
        :snapshot,
        opts
      )
    else
      {:error, error} -> error(error)
    end
  end

  def volume(target, source, pool, source_pool, volume, opts \\ []) do
    with :ok <- authorize(target, source, opts, [:volume_only, :refresh, :refresh_exclude_older]),
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
          "name" => opts[:name] || "",
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
    type = if kind == :volume, do: "StorageVolumesPost", else: "InstancesPost"

    with {:ok, body} <- NativeInput.cast(type, body),
         {:ok, source_request} <- typed_source(source_request, kind) do
      target_request = {method, args, body}

      if local_copy?(target, source, location, kind) do
        dispatch_local(target, source, method, args, body, name, kind)
      else
        with :ok <- required(target, kind == :volume, "storage_api_remote_volume_handling") do
          Migration.negotiate(source, target, source_request, target_request,
            mode: opts[:mode] || :pull,
            approved_origin: opts[:approved_origin]
          )
        end
      end
    else
      {:error, cause} -> error(cause)
      _ -> error(:invalid_copy_model)
    end
  end

  defp typed_source({method, args, body}, kind) do
    type =
      %{instance: "InstancePost", snapshot: "InstanceSnapshotPost", volume: "StorageVolumePost"}[
        kind
      ]

    with {:ok, body} <- NativeInput.cast(type, body), do: {:ok, {method, args, body}}
  end

  defp local_copy?(target, source, location, kind) do
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

    colocated = colocated?(location, target.connection.member, kind)

    local and (internal or colocated or (kind != :volume and not clustered))
  end

  defp colocated?(location, member, kind),
    do: location == member or (kind == :volume and location == "none" and is_nil(member))

  defp dispatch_local(target, source, method, args, body, name, kind) do
    internal =
      Incus.has_extension?(
        target,
        if(kind == :volume,
          do: "cluster_internal_custom_volume_copy",
          else: "cluster_internal_copy"
        )
      )

    different_project =
      (source.connection.project || "default") != (target.connection.project || "default")

    with :ok <-
           required(
             target,
             different_project,
             if(kind == :volume, do: "storage_api_project", else: "container_copy_project")
           ) do
      fields =
        if kind != :volume,
          do: %{"type" => "copy", "source" => name},
          else: %{"type" => "copy"}

      fields =
        if different_project,
          do: Map.put(fields, "project", source.connection.project || "default"),
          else: fields

      fields =
        if kind == :volume and internal,
          do:
            Map.put(
              fields,
              "location",
              source_location(source)
            ),
          else: fields

      body = Map.put(body, "source", Map.merge(body["source"], fields))
      body = if kind == :snapshot, do: Map.put(body, "type", ""), else: body

      with {:ok, response} <- Incus.call(target, method, args, body: body),
           {:ok, operation} <- Operation.from_response(target, response),
           do: {:ok, %Migration{mode: :local, target: operation}}
    end
  end

  defp source_location(source),
    do: source.connection.member || (source.server.environment || %{})["server_name"] || ""

  defp authorize(target, source, opts, allowed) do
    with :ok <- Context.authorize(target.context, target.connection),
         :ok <- Context.authorize(source.context, source.connection),
         true <- valid_options?(opts, [:name, :mode, :approved_origin] ++ allowed),
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
           is_nil(opts[:name]) or (is_binary(opts[:name]) and byte_size(opts[:name]) in 0..1024),
         do: :ok,
         else: (
           {:error, error} -> {:error, error}
           _ -> {:error, :invalid_copy_options}
         )
  end

  defp name_or(opts, fallback),
    do: if(opts[:name] in [nil, ""], do: fallback, else: opts[:name])

  defp valid_options?(opts, allowed),
    do:
      Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
        length(opts) == length(Enum.uniq(Keyword.keys(opts)))

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
         do:
           required(target, opts[:allow_inconsistent] == true, "instance_allow_inconsistent_copy")
  end

  defp mode_extensions(target, source, opts) do
    with :ok <- required(target, opts[:mode] in [:push, :relay], "container_push"),
         :ok <- required(source, opts[:mode] in [:push, :relay], "container_push"),
         do: required(source, opts[:mode] == :push, "container_push_target")
  end

  defp source_fields(kind, fields) when kind in [:instance, :snapshot] do
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

  defp valid_name?(value),
    do:
      is_binary(value) and byte_size(value) in 1..1024 and
        not String.contains?(value, ["\r", "\n", <<0>>])

  defp escape(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
