defmodule Opsmaru.Incus.Files do
  @moduledoc "Native file/directory and backup handoff with host-owned bounded binary sources/sinks."
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.FileHeaders
  alias Opsmaru.Incus.Model
  alias Opsmaru.Incus.Response
  alias Opsmaru.Incus.Transfer

  def read(client, instance, path, sink) do
    read_path(client, file_path(instance, path), sink)
  end

  def volume_read(client, pool, type, name, path, sink),
    do:
      read_path(
        client,
        volume_path(pool, type, name) <> "/files?" <> URI.encode_query(path: path),
        sink
      )

  defp read_path(client, path, sink) do
    ref = make_ref()

    handler = fn
      {:headers, headers} ->
        previous = Process.get(ref)

        if previous,
          do: Process.put(ref, %{previous | headers: Map.merge(previous.headers, headers)}),
          else:
            Process.put(ref, %{
              headers: headers,
              type: headers["x-incus-type"] || "file",
              body: [],
              bytes: 0
            })

        :ok

      {:data, bytes} ->
        state = Process.get(ref)

        if state.type == "directory" do
          if state.bytes + byte_size(bytes) <= client.connection.max_response_bytes do
            Process.put(ref, %{
              state
              | body: [bytes | state.body],
                bytes: state.bytes + byte_size(bytes)
            })

            :ok
          else
            {:error, :response_limit}
          end
        else
          sink.(bytes)
        end

      :done ->
        state = Process.get(ref)

        with {:ok, parsed} <- FileHeaders.parse(state.headers) do
          info = Map.merge(parsed, %{entries: nil, headers: state.headers})
          finish_read(state, info)
        end
    end

    Transfer.download_events(client, path, handler)
  end

  defp finish_read(%{type: "directory"} = state, info) do
    with {:ok, response} <-
           Response.decode(IO.iodata_to_binary(Enum.reverse(state.body)), 200, state.headers),
         true <- is_list(response.metadata) and Enum.all?(response.metadata, &is_binary/1),
         do: {:ok, %{info | entries: response.metadata}}
  end

  defp finish_read(_, info), do: {:ok, info}

  def create(client, instance, path, source, opts \\ []) do
    create_path(client, file_path(instance, path), source, opts)
  end

  def volume_create(client, pool, type, name, path, source, opts \\ []),
    do:
      create_path(
        client,
        volume_path(pool, type, name) <> "/files?" <> URI.encode_query(path: path),
        source,
        opts
      )

  def volume_delete(client, pool, type, name, path) do
    if Enum.all?([pool, type, name, path], &(is_binary(&1) and byte_size(&1) <= 1024)) do
      Incus.raw_query(
        client,
        "DELETE",
        volume_path(pool, type, name) <> "/files?" <> URI.encode_query(path: path)
      )
    else
      {:error, %Error{kind: :invalid_file_options}}
    end
  end

  defp create_path(client, path, source, opts) do
    type = opts[:type] || "file"

    with :ok <- extension(client, type),
         :ok <- append(client, opts[:write_mode]),
         {:ok, headers} <- headers(type, opts) do
      Transfer.upload(client, path, source, headers)
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, %Error{kind: :invalid_file_options}}
    end
  end

  def volume_backup_download(client, pool, type, name, backup, sink) do
    with :ok <- Incus.require_extension(client, "custom_volume_backup"),
         do:
           Transfer.download(
             client,
             volume_path(pool, type, name) <> "/backups/" <> escape(backup) <> "/export",
             sink
           )
  end

  def bucket_backup_download(client, pool, name, backup, sink) do
    with :ok <- Incus.require_extension(client, "storage_bucket_backup"),
         do:
           Transfer.download(
             client,
             bucket_path(pool, name) <> "/backups/" <> escape(backup) <> "/export",
             sink
           )
  end

  def volume_import(client, pool, source, opts \\ []) do
    iso = opts[:type] == :iso

    with :ok <-
           Incus.require_extension(
             client,
             if(iso, do: "custom_volume_iso", else: "custom_volume_backup")
           ),
         :ok <-
           if(iso, do: :ok, else: override_extension(client, opts[:name], "backup_override_name")),
         true <- not iso or (is_binary(opts[:name]) and opts[:name] != "") do
      headers = [{"content-type", "application/octet-stream"}]
      headers = if opts[:name], do: [{"x-incus-name", opts[:name]} | headers], else: headers
      headers = if iso, do: [{"x-incus-type", "iso"} | headers], else: headers

      Transfer.upload(
        client,
        "/1.0/storage-pools/" <> escape(pool) <> "/volumes/custom",
        source,
        headers
      )
    else
      {:error, error} -> {:error, error}
      _ -> {:error, %Error{kind: :invalid_file_options}}
    end
  end

  def bucket_import(client, pool, source, opts \\ []) do
    with :ok <- Incus.require_extension(client, "storage_bucket_backup") do
      headers = [{"content-type", "application/octet-stream"}]
      headers = if opts[:name], do: [{"x-incus-name", opts[:name]} | headers], else: headers

      Transfer.upload(
        client,
        "/1.0/storage-pools/" <> escape(pool) <> "/buckets",
        source,
        headers
      )
    end
  end

  @doc "Direct native backup POST to a binary sink; resource is an instance, volume or bucket tuple."
  def backup_stream(client, resource, body, sink) do
    {path, type} =
      case resource do
        {:instance, name} ->
          {"/1.0/instances/" <> escape(name), "InstanceBackupsPost"}

        {:volume, pool, volume_type, name} ->
          {volume_path(pool, volume_type, name), "StorageVolumeBackupsPost"}

        {:bucket, pool, name} ->
          {bucket_path(pool, name), "StorageBucketBackupsPost"}
      end

    with :ok <- Incus.require_extension(client, "direct_backup"),
         {:ok, model} <- Model.decode(type, Model.encode(body)),
         bytes = Jason.encode!(model.data) <> "\n",
         true <-
           byte_size(bytes) <=
             min(client.connection.max_request_bytes, client.connection.max_chunk_bytes) do
      Transfer.download_post(client, path <> "/backups", [bytes], sink, [
        {"accept", "application/octet-stream"}
      ])
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, %Error{kind: :invalid_body}}
    end
  end

  defp volume_path(pool, type, name),
    do:
      "/1.0/storage-pools/" <> escape(pool) <> "/volumes/" <> escape(type) <> "/" <> escape(name)

  defp bucket_path(pool, name),
    do: "/1.0/storage-pools/" <> escape(pool) <> "/buckets/" <> escape(name)

  def backup_download(client, instance, name, sink) do
    with :ok <- Incus.require_extension(client, "container_backup"),
         do:
           Transfer.download(
             client,
             "/1.0/instances/" <> escape(instance) <> "/backups/" <> escape(name) <> "/export",
             sink
           )
  end

  def backup_import(client, source, opts \\ []) do
    with :ok <- Incus.require_extension(client, "container_backup"),
         :ok <- override_extension(client, opts[:pool], "container_backup_override_pool"),
         :ok <- override_extension(client, opts[:name], "backup_override_name"),
         :ok <- override_extension(client, opts[:config], "backup_override_config"),
         :ok <- override_extension(client, opts[:devices], "backup_override_config") do
      headers = [{"content-type", "application/octet-stream"}]

      headers =
        Enum.reduce([{:name, "x-incus-name"}, {:pool, "x-incus-pool"}], headers, fn {option,
                                                                                     header},
                                                                                    headers ->
          if opts[option], do: [{header, opts[option]} | headers], else: headers
        end)

      headers =
        Enum.reduce([:config, :devices], headers, fn key, headers ->
          if is_nil(opts[key]),
            do: headers,
            else: [{"x-incus-" <> Atom.to_string(key), Enum.join(opts[key], " ")} | headers]
        end)

      Transfer.upload(client, "/1.0/instances", source, headers)
    end
  end

  defp override_extension(_, value, _) when value in [nil, ""], do: :ok
  defp override_extension(client, _, extension), do: Incus.require_extension(client, extension)

  defp extension(client, "directory"),
    do: Incus.require_extension(client, "directory_manipulation")

  defp extension(client, "symlink"), do: Incus.require_extension(client, "file_symlinks")
  defp extension(_, "file"), do: :ok
  defp extension(_, _), do: {:error, :invalid_type}
  defp append(client, "append"), do: Incus.require_extension(client, "file_append")
  defp append(_, mode) when mode in [nil, "overwrite"], do: :ok
  defp append(_, _), do: {:error, :invalid_write_mode}

  defp headers(type, opts) do
    base = [{"x-incus-type", type}, {"x-incus-write", opts[:write_mode] || "overwrite"}]

    Enum.reduce_while([{:uid, 10}, {:gid, 10}, {:mode, 8}], {:ok, base}, fn {key, radix},
                                                                            {:ok, headers} ->
      value = opts[key]

      cond do
        is_nil(value) or value == -1 ->
          {:cont, {:ok, headers}}

        is_integer(value) and value >= 0 ->
          encoded = Integer.to_string(value, radix)
          encoded = if radix == 8, do: String.pad_leading(encoded, 4, "0"), else: encoded
          {:cont, {:ok, [{"x-incus-" <> Atom.to_string(key), encoded} | headers]}}

        true ->
          {:halt, {:error, :invalid_file_mode}}
      end
    end)
  end

  defp file_path(instance, path),
    do: "/1.0/instances/" <> escape(instance) <> "/files?" <> URI.encode_query(path: path)

  defp escape(value),
    do: URI.encode(value, fn char -> URI.char_unreserved?(char) or char in ~c"$&+:=@" end)
end
