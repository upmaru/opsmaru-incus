defmodule Opsmaru.Incus.OCI do
  @moduledoc """
  Portable pinned OCI image semantics through an explicit host-owned adapter.

  `new!/4` is passive. `resolve/3` inspects an alias and returns native alias/image
  models plus a new immutable cache value; `image/2` reads that cache. No global
  cache, command runner, filesystem state or credential generation is involved.
  `image_file/3` delivers converted binary metadata/rootfs to acknowledged sinks.
  Registry authentication and installed conversion remain host acceptance gates.
  """
  alias Opsmaru.Context
  alias Opsmaru.Incus.{Connection, Discovery, Error, HTTP, Model, NativeInput, Response}
  alias Opsmaru.Incus.OCI.AdapterCall
  @enforce_keys [:connection, :context, :adapter, :config]
  defstruct [:connection, :context, :adapter, :config, cache: %{}]
  @type t :: %__MODULE__{}

  @architectures %{
    "i686" => ~w(i386 i586 386 x86 generic_32),
    "x86_64" => ~w(amd64 generic_64 x86_64_v1 x86_64_v2 x86_64_v3 x86_64_v4),
    "armv6l" => ~w(armel arm),
    "armv7l" => ~w(armhf armhfp armv7a_hardfp armv7 armv7a_vfpv3_hardfp),
    "armv8l" => [],
    "aarch64" => ~w(arm64 arm64_generic),
    "ppc" => ~w(powerpc),
    "ppc64" => ~w(powerpc64),
    "ppc64le" => ~w(ppc64el),
    "s390x" => [],
    "mips" => ~w(mipsel mipsle),
    "mips64" => ~w(mips64el mips64le),
    "riscv32" => [],
    "riscv64" => [],
    "loongarch64" => ~w(loong64)
  }

  def new!(%Connection{} = connection, %Context{} = context, adapter, config)
      when is_atom(adapter) do
    unless Enum.all?([{:inspect_image, 2}, {:image_file, 3}, {:cleanup, 3}], fn {name, arity} ->
             Code.ensure_loaded?(adapter) and function_exported?(adapter, name, arity)
           end),
           do: raise(ArgumentError, "OCI requires an explicit complete host adapter")

    %__MODULE__{connection: connection, context: context, adapter: adapter, config: config}
  end

  @doc "Resolve a container alias; native OCI rejects virtual-machine image types."
  def resolve(client, name, image_type \\ "") do
    with :ok <- authorize(client),
         :ok <- container(image_type),
         :ok <- alias_name(name),
         :ok <- capacity(client),
         alias_name = normalize_alias(name),
         {:ok, info} <- inspect_image(client, alias_name),
         {:ok, alias_model, image_model} <- project(info, alias_name) do
      fingerprint = image_model.data["fingerprint"]
      entry = %{info: info, alias: alias_name, image: image_model}
      next = %{client | cache: Map.put(client.cache, fingerprint, entry)}
      {:ok, %{alias: alias_model, image: image_model}, next}
    end
  end

  @doc "Read a previously resolved image; the original client cache remains unchanged."
  def image(client, fingerprint) do
    with :ok <- authorize(client),
         {:ok, entry} <- entry(client, fingerprint),
         do: {:ok, response(client, entry.image)}
  end

  @doc "Native OCI alias architecture mapping; the host explicitly supplies its local architecture."
  def alias_architectures(client, name, local_architecture, image_type \\ "") do
    with :ok <- authorize(client),
         :ok <- container(image_type),
         {:ok, architecture} <- architecture(local_architecture),
         {:ok, %{alias: alias_model}, next} <- resolve(client, name, image_type) do
      {:ok, %{architecture => alias_model}, next}
    else
      :error -> error(:invalid_architecture, nil)
      result -> result
    end
  end

  @doc "Native no-op disconnect; no persistent connection or host conversion is owned by this value."
  def disconnect(%__MODULE__{}), do: :ok

  @doc "Passive native OCI origin metadata; the explicit HTTPS connection is not inferred from adapter config."
  def connection_info(client) do
    with :ok <- authorize(client),
         :ok <- https_origin(client) do
      url = URI.to_string(client.connection.address)

      {:ok,
       %Discovery{
         certificate: "",
         protocol: "oci",
         url: url,
         addresses: [url],
         project: "",
         target: "",
         socket_path: ""
       }}
    end
  end

  @doc "Passive bounded HTTP handle on the explicitly supplied verified HTTPS origin; no conversion adapter call."
  def http_client(client) do
    with :ok <- https_origin(client), do: HTTP.client(client)
  end

  def http_request(client, method, path, opts \\ []) do
    with {:ok, handle} <- http_client(client), do: HTTP.request(handle, method, path, opts)
  end

  defp https_origin(%__MODULE__{connection: %Connection{transport: :https}}), do: :ok
  defp https_origin(_), do: error(:invalid_origin, nil)

  @doc "Convert through the host adapter; both native output sinks are explicit."
  def image_file(client, fingerprint, %{metadata: metadata, rootfs: rootfs})
      when is_function(metadata, 1) and is_function(rootfs, 1) do
    with :ok <- authorize(client),
         {:ok, entry} <- entry(client, fingerprint) do
      request = request(client, entry.alias) |> Map.put(:info, entry.info)

      AdapterCall.run(client, request, client.connection.stream_timeout, fn request ->
        stream(client, request, metadata, rootfs)
      end)
    end
  end

  def image_file(_, _, _), do: error(:invalid_arguments, "No file requested")

  @doc "Native unsupported OCI methods, without probing a registry or a host tool."
  def unsupported(client, method) do
    with :ok <- authorize(client) do
      cond do
        method in ~w(GetImages GetImagesAllProjects GetImagesAllProjectsWithFilter GetImagesWithFilter GetImageFingerprints) ->
          error(:native, "Can't list images from OCI registry")

        method in ~w(GetImageAliases GetImageAliasNames) ->
          error(:native, "Can't list image aliases from OCI registry")

        method in ~w(GetImageSecret GetPrivateImage GetPrivateImageFile) ->
          error(:native, "Private images aren't supported with OCI registry")

        method == "ExportImage" ->
          error(:native, "Exporting images is not supported with OCI registry")

        true ->
          error(:missing_method, nil)
      end
    end
  end

  defp inspect_image(client, alias_name) do
    AdapterCall.run(client, request(client, alias_name), client.connection.timeout, fn request ->
      with {:ok, json} when is_binary(json) <- adapter_inspection(client, request),
           true <- byte_size(json) <= min(client.connection.max_response_bytes, 1_048_576),
           {:ok, info} when is_map(info) <- Jason.decode(json),
           {:ok, info} <- inspection(info) do
        {:ok, info}
      else
        {:error, %Error{} = error} -> {:error, error}
        _ -> error(:invalid_oci_inspection, nil)
      end
    end)
  end

  defp adapter_inspection(client, request) do
    case client.adapter.inspect_image(client.config, request) do
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, %Error{kind: :adapter_failed, response: reason}}
      result -> result
    end
  end

  defp inspection(info) do
    with {:ok, created} <- NativeInput.cast("time.Time", info["Created"]),
         {:ok, architecture} <- architecture(info["Architecture"] || ""),
         {:ok, name} <- NativeInput.cast("string", info["Name"]),
         {:ok, layers} <- NativeInput.cast("[]string", info["Layers"]),
         {:ok, sizes} <- sizes(info["LayersData"]) do
      {:ok,
       %{
         "Name" => name,
         "Created" => created,
         "Architecture" => architecture,
         "Layers" => layers,
         "LayersData" => sizes
       }}
    else
      _ -> error(:invalid_oci_inspection, nil)
    end
  end

  defp sizes(nil), do: {:ok, []}

  defp sizes(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn item, {:ok, acc} ->
      value = if is_map(item), do: item["Size"], else: nil

      case {is_nil(item) or is_map(item), NativeInput.cast("int64", value)} do
        {true, {:ok, size}} -> {:cont, {:ok, [%{"Size" => size} | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, sizes} -> {:ok, Enum.reverse(sizes)}
      _ -> :error
    end
  end

  defp sizes(_), do: :error

  defp project(info, alias_name) do
    fingerprint =
      :crypto.hash(:sha256, Enum.join(info["Layers"] || [], ""))
      |> Base.encode16(case: :lower)

    data = %{
      "public" => true,
      "properties" => %{
        "architecture" => info["Architecture"],
        "type" => "oci",
        "description" => info["Name"] <> " (OCI)",
        "id" => alias_name
      },
      "aliases" => [%{"name" => alias_name}],
      "architecture" => info["Architecture"],
      "fingerprint" => fingerprint,
      "type" => "container",
      "created_at" => info["Created"],
      "uploaded_at" => info["Created"],
      "size" => signed_sum(info["LayersData"])
    }

    with {:ok, image} <- NativeInput.cast("Image", data),
         {:ok, image_model} <- Model.decode("Image", image),
         {:ok, alias_data} <-
           NativeInput.cast("ImageAliasesEntry", %{
             "name" => alias_name,
             "target" => fingerprint,
             "type" => "container"
           }),
         {:ok, alias_model} <- Model.decode("ImageAliasesEntry", alias_data),
         do: {:ok, alias_model, image_model}
  end

  # The pinned Go int64 accumulation wraps rather than saturating.
  defp signed_sum(sizes) do
    value = rem(Enum.sum(Enum.map(sizes, & &1["Size"])), 18_446_744_073_709_551_616)
    value = if value < 0, do: value + 18_446_744_073_709_551_616, else: value
    if value >= 9_223_372_036_854_775_808, do: value - 18_446_744_073_709_551_616, else: value
  end

  defp stream(client, request, metadata, rootfs) do
    key = make_ref()
    Process.put(key, %{metadata: 0, rootfs: 0, failed: false})
    rejected = :atomics.new(1, [])
    worker = self()

    emit = fn part, bytes ->
      cond do
        self() != worker ->
          :atomics.put(rejected, 1, 1)
          {:error, :foreign_emitter}

        :atomics.get(rejected, 1) != 0 ->
          {:error, :stream_limit}

        true ->
          emit(key, part, bytes, %{metadata: metadata, rootfs: rootfs}, client, request)
      end
    end

    result = client.adapter.image_file(client.config, request, emit)
    counts = Process.delete(key)

    cond do
      result == :ok and not counts.failed and :atomics.get(rejected, 1) == 0 ->
        {:ok,
         %{
           meta_name: "metadata.tar.gz",
           rootfs_name: "rootfs.tar.gz",
           meta_size: counts.metadata,
           rootfs_size: counts.rootfs
         }}

      match?({:error, %Error{}}, result) ->
        result

      match?({:error, _}, result) ->
        {:error, %Error{kind: :adapter_stream, response: elem(result, 1)}}

      true ->
        error(:adapter_stream, nil)
    end
  end

  defp emit(key, part, bytes, sinks, client, request) do
    counts = Process.get(key)

    if part in [:metadata, :rootfs] and is_binary(bytes) and not counts.failed and
         byte_size(bytes) <= client.connection.max_chunk_bytes and
         counts.metadata + counts.rootfs + byte_size(bytes) <= client.connection.max_stream_bytes and
         System.monotonic_time(:millisecond) < request.deadline and
         acknowledge(sinks[part], bytes) do
      Process.put(key, Map.update!(counts, part, &(&1 + byte_size(bytes))))
      :ok
    else
      Process.put(key, %{counts | failed: true})
      {:error, :stream_limit}
    end
  end

  defp acknowledge(sink, bytes) do
    sink.(bytes) == :ok
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp request(client, alias_name),
    do: %{connection: client.connection, context: client.context, alias: alias_name}

  defp authorize(client) do
    case Context.authorize(client.context, client.connection) do
      :ok -> :ok
      {:error, kind} -> error(kind, nil)
    end
  end

  defp capacity(client) do
    if map_size(client.cache) < min(client.connection.queue_limit, 128),
      do: :ok,
      else: error(:oci_cache_limit, nil)
  end

  defp entry(client, fingerprint) do
    case Map.fetch(client.cache, fingerprint) do
      {:ok, entry} -> {:ok, entry}
      :error -> error(:native, "Image not found")
    end
  end

  defp normalize_alias(name) do
    case String.split(name, "@", parts: 2) do
      [name, hash] -> hd(String.split(name, ":", parts: 2)) <> "@" <> hash
      _ -> name
    end
  end

  defp alias_name(name) do
    if is_binary(name) and byte_size(name) in 1..1024 and String.valid?(name) and
         not String.contains?(name, [<<0>>, "\r", "\n"]),
       do: :ok,
       else: error(:invalid_arguments, nil)
  end

  defp container("virtual-machine"),
    do: error(:native, "OCI images are only supported for containers")

  defp container(type) when is_binary(type), do: :ok
  defp container(_), do: error(:invalid_arguments, nil)

  defp architecture(name) do
    case Enum.find(@architectures, fn {native, aliases} -> name == native or name in aliases end) do
      {native, _} -> {:ok, native}
      nil -> :error
    end
  end

  defp response(client, model),
    do: %Response{
      type: "sync",
      metadata: model,
      connection: client.connection,
      identity: client.context.identity
    }

  defp error(kind, message), do: {:error, %Error{kind: kind, message: message}}
end

defimpl Inspect, for: Opsmaru.Incus.OCI do
  def inspect(_, _), do: "#Opsmaru.Incus.OCI<host adapter and cache redacted>"
end
