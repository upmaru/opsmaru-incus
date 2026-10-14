defmodule Opsmaru.Incus.SimpleStreams do
  @moduledoc """
  Explicit verified-HTTPS SimpleStreams catalog. Construction is passive;
  `refresh/1` returns a new immutable connection-local catalog. The host supplies
  its native architecture explicitly, including any pinned platform fallback.

  Catalog responses share one request deadline and aggregate byte/entry bounds.
  There is no disk cache, socket discovery, HTTP downgrade or automatic retry.
  An optional host delta adapter owns conversion and temporary state; installed
  conversion remains a separate acceptance gate.
  """
  alias Opsmaru.Incus.{Connection, Context, Discovery, Error, HTTP, Transport}
  alias Opsmaru.Incus.SimpleStreams.{Catalog, Download}
  @enforce_keys [:connection, :context, :architecture]
  defstruct [:connection, :context, :architecture, :catalog, :delta_adapter, :delta_config]

  def new!(%Connection{transport: :https} = connection, %Context{} = context, opts) do
    unless Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:architecture, :delta_adapter, :delta_config] == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
             is_nil(connection.project) and is_nil(connection.member) and
             not connection.require_authenticated,
           do:
             raise(ArgumentError, "SimpleStreams requires explicit HTTPS and native architecture")

    case Catalog.architecture(opts[:architecture]) do
      {:ok, architecture} ->
        adapter = delta_adapter!(opts)

        %__MODULE__{
          connection: connection,
          context: context,
          architecture: architecture,
          delta_adapter: adapter,
          delta_config: opts[:delta_config]
        }

      _ ->
        raise ArgumentError, "Unsupported SimpleStreams architecture"
    end
  end

  def new!(_, _, _), do: raise(ArgumentError, "SimpleStreams requires explicit HTTPS")

  @doc "Native no-op disconnect; the immutable catalog owns no pool, files or conversion worker."
  def disconnect(%__MODULE__{}), do: :ok

  @doc "Native origin metadata without network or credential-file access. Public PEM is not inferred from trust references."
  def connection_info(client) do
    with :ok <- authorize(client) do
      url = URI.to_string(client.connection.address)

      {:ok,
       %Discovery{
         certificate: "",
         protocol: "simplestreams",
         url: url,
         addresses: [url],
         project: "",
         target: "",
         socket_path: ""
       }}
    end
  end

  @doc "Immutable HTTP handle confined to this verified origin; construction performs no I/O."
  def http_client(%__MODULE__{} = client), do: HTTP.client(client)

  @doc "Bounded raw HTTP request on the explicit origin; redirects and mutations are never replayed."
  def http_request(client, method, path, opts \\ []) do
    with {:ok, handle} <- http_client(client), do: HTTP.request(handle, method, path, opts)
  end

  defp delta_adapter!(opts) do
    case {opts[:delta_adapter], Keyword.has_key?(opts, :delta_config)} do
      {nil, false} ->
        nil

      {adapter, true} when is_atom(adapter) and not is_nil(adapter) ->
        unless Code.ensure_loaded?(adapter) and function_exported?(adapter, :convert, 3) and
                 function_exported?(adapter, :cleanup, 3),
               do: raise(ArgumentError, "Delta conversion requires a complete host adapter")

        adapter

      _ ->
        raise ArgumentError, "Delta conversion requires explicit adapter configuration"
    end
  end

  def refresh(client) do
    with :ok <- authorize(client) do
      Transport.bounded(
        client.connection.timeout,
        "GET",
        fn ->
          refresh_catalog(client)
        end,
        client.connection.request_context
      )
    end
  end

  def images(client), do: read(client, &{:ok, &1.images})

  def fingerprints(client),
    do: read(client, &{:ok, Enum.map(&1.images, fn image -> image.data["fingerprint"] end)})

  def image(client, fingerprint) when is_binary(fingerprint) do
    read(client, fn catalog ->
      case Enum.filter(catalog.images, &String.starts_with?(&1.data["fingerprint"], fingerprint)) do
        [image] ->
          {:ok, image}

        [] ->
          error(:native, "Failed getting image: The requested image couldn't be found")

        _ ->
          error(
            :native,
            "Failed getting image: More than one match for the provided partial fingerprint"
          )
      end
    end)
  end

  def aliases(client) do
    read(client, fn catalog ->
      values = Catalog.preferred_aliases(catalog) |> Enum.map(& &1.model)
      {:ok, Enum.uniq_by(values, &{&1.data["name"], &1.data["type"]})}
    end)
  end

  def alias_names(client) do
    with {:ok, aliases} <- aliases(client), do: {:ok, Enum.map(aliases, & &1.data["name"])}
  end

  def alias(client, name, type \\ "") when is_binary(name) and is_binary(type) do
    read(client, fn catalog ->
      matches = alias_matches(Catalog.preferred_aliases(catalog), name, type)

      case matches do
        [entry | _] -> {:ok, entry.model}
        [] -> error(:native, "Alias '#{name}' doesn't exist")
      end
    end)
  end

  def alias_architectures(client, name, type \\ "") when is_binary(name) and is_binary(type) do
    read(client, fn catalog ->
      matches = alias_matches(catalog.aliases, name, type)

      if matches == [],
        do: error(:native, "Alias '#{name}' doesn't exist"),
        else: {:ok, Map.new(matches, &{&1.architecture, &1.model})}
    end)
  end

  def files(client, fingerprint) do
    with {:ok, image} <- image(client, fingerprint),
         do: {:ok, client.catalog.files[image.data["fingerprint"]]}
  end

  @doc "Download selected image parts through acknowledged host sinks; verify SHA-256 and sizes."
  def image_file(client, fingerprint, sinks, opts \\ []),
    do: Download.run(client, fingerprint, sinks, opts)

  def unsupported(client, method) do
    with :ok <- authorize(client) do
      case method do
        name when name in ~w(GetImagesWithFilter GetImagesAllProjectsWithFilter) ->
          error(:native, "GetImagesWithFilter is not supported by the simplestreams protocol")

        name when name in ~w(GetImageSecret GetPrivateImage GetPrivateImageFile) ->
          error(:native, "Private images aren't supported by the simplestreams protocol")

        "ExportImage" ->
          error(:native, "Exporting images is not supported by the simplestreams protocol")

        _ ->
          error(:missing_method, nil)
      end
    end
  end

  defp alias_matches(aliases, name, "") do
    matches = alias_matches(aliases, name, "container")
    if matches == [], do: alias_matches(aliases, name, "virtual-machine"), else: matches
  end

  defp alias_matches(aliases, name, type),
    do: Enum.filter(aliases, &(&1.model.data["name"] == name and &1.model.data["type"] == type))

  defp refresh_catalog(client) do
    deadline = now() + client.connection.timeout

    with {:ok, index, bytes} <- json(client, "/streams/v1/index.json", deadline),
         entries when is_map(entries) <- index["index"],
         :ok <- capacity(map_size(entries), client.connection.queue_limit),
         paths =
           for(
             {_, entry} <- entries,
             entry["datatype"] == "image-downloads" and entry["products"] not in [nil, []],
             do: entry["path"]
           ),
         {:ok, products} <- products(client, paths, deadline, bytes),
         {:ok, catalog} <- Catalog.build(products, client.architecture) do
      if length(catalog.images) <= client.connection.queue_limit,
        do: {:ok, %{client | catalog: catalog}},
        else: error(:catalog_limit, nil)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> error(kind, nil)
      _ -> error(:invalid_simplestreams_catalog, nil)
    end
  end

  defp capacity(count, limit) when count <= limit, do: :ok
  defp capacity(_, _), do: error(:catalog_limit, nil)

  defp products(client, paths, deadline, bytes) do
    Enum.reduce_while(paths, {:ok, [], bytes, 0}, fn path, {:ok, acc, used, count} ->
      with {:ok, data, size} <- json(client, path, deadline),
           entries when is_map(entries) <- data["products"],
           true <- used + size <= client.connection.max_response_bytes,
           true <- map_size(entries) <= client.connection.queue_limit,
           weight = candidate_count(entries, client.connection.queue_limit),
           true <- count + weight <= client.connection.queue_limit do
        {:cont, {:ok, Map.values(entries) ++ acc, used + size, count + weight}}
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
        _ -> {:halt, error(:catalog_limit, nil)}
      end
    end)
    |> case do
      {:ok, values, _, _} -> {:ok, values}
      error -> error
    end
  end

  defp candidate_count(entries, limit) do
    Enum.sum(
      for {_, product} <- entries, {_, version} <- product["versions"] || %{} do
        items = Map.values(version["items"] || %{})

        count =
          Enum.count(items, &(&1["ftype"] == "incus_combined.tar.gz")) +
            Enum.count(items, &(&1["ftype"] == "incus.tar.xz")) *
              Enum.count(
                items,
                &(&1["ftype"] in ~w(squashfs root.tar.xz disk-kvm.img uefi1.img disk1.img))
              )

        names = product["aliases"] || ""
        aliases = if names == "", do: 0, else: length(String.split(names, ",", parts: limit + 2))
        count * (1 + 2 * aliases)
      end
    )
  end

  defp json(client, path, deadline) do
    with {:ok, path} <- path(path),
         true <- deadline > now(),
         connection = %{client.connection | timeout: max(1, deadline - now())},
         {:ok, response} <- Transport.request(connection, "GET", path, [], nil),
         true <- response.status == 200,
         {:ok, data} when is_map(data) <- Jason.decode(response.body) do
      {:ok, data, byte_size(response.body)}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> error(:simplestreams_response, nil)
    end
  end

  @doc false
  def path(value) when is_binary(value) and byte_size(value) <= 16_384 do
    uri = URI.parse(value)
    decoded = URI.decode(uri.path || "")

    if not String.valid?(value) || remote_path?(uri) ||
         String.starts_with?(value, "//") || String.contains?(decoded, ["\\", "\r", "\n", <<0>>]) ||
         Enum.any?(String.split(decoded, "/"), &(&1 in [".", ".."])) ||
         Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value),
       do: error(:invalid_path, nil),
       else: {:ok, "/" <> URI.encode(String.trim_leading(uri.path || "", "/"), &path_char?/1)}
  rescue
    _ -> error(:invalid_path, nil)
  end

  def path(_), do: error(:invalid_path, nil)

  defp path_char?(char), do: URI.char_unreserved?(char) or char in ~c"/%:@!$&'()*+,;="

  defp remote_path?(uri),
    do: Enum.any?([uri.host, uri.scheme, uri.query, uri.fragment], &(not is_nil(&1)))

  defp read(client, fun) do
    with :ok <- authorize(client),
         true <- is_map(client.catalog) do
      fun.(client.catalog)
    else
      {:error, _} = error -> error
      _ -> error(:catalog_not_loaded, nil)
    end
  end

  defp authorize(client) do
    case Context.authorize(client.context, client.connection) do
      :ok -> :ok
      {:error, kind} -> error(kind, nil)
    end
  end

  defp error(kind, message), do: {:error, %Error{kind: kind, message: message}}
  defp now, do: System.monotonic_time(:millisecond)
end

defimpl Inspect, for: Opsmaru.Incus.SimpleStreams do
  def inspect(_, _), do: "#Opsmaru.Incus.SimpleStreams<explicit HTTPS catalog redacted>"
end
