defmodule Opsmaru.Incus.SimpleStreams do
  @moduledoc """
  Explicit verified-HTTPS SimpleStreams catalog. Construction is passive;
  `refresh/1` returns a new immutable connection-local catalog. The host supplies
  its native architecture explicitly, including any pinned platform fallback.

  Catalog responses share one request deadline and aggregate byte/entry bounds.
  There is no socket discovery, HTTP downgrade or automatic retry. An optional
  host cache adapter keeps the pinned cache directory's expiry, stale fallback
  and invalidation without shared code writing files. An optional host delta
  adapter owns conversion and temporary state; installed conversion and cache
  storage remain separate acceptance gates.

  `certificate:` is the pinned `TLSServerCert`: one public PEM certificate that
  `connection_info/1` reports and copies send as the source certificate. It is
  empty by default, which tells a target to use system trust.
  """
  alias Opsmaru.Incus.{Connection, Context, Discovery, Error, HTTP, StatusError, Transport}
  alias Opsmaru.Incus.SimpleStreams.{Catalog, Download}
  @enforce_keys [:connection, :context, :architecture]
  defstruct [
    :connection,
    :context,
    :architecture,
    :catalog,
    :delta_adapter,
    :delta_config,
    :cache,
    certificate: ""
  ]

  @options ~w(architecture delta_adapter delta_config certificate cache_adapter cache_config cache_expiry)a
  # The pinned ConnectSimpleStreams default when CacheExpiry is zero.
  @cache_expiry 3_600_000

  def new!(%Connection{transport: :https} = connection, %Context{} = context, opts) do
    unless Keyword.keyword?(opts) and
             Keyword.keys(opts) -- @options == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
             is_nil(connection.project) and is_nil(connection.member) and
             not connection.require_authenticated,
           do:
             raise(ArgumentError, "SimpleStreams requires explicit HTTPS and native architecture")

    unless certificate?(Keyword.get(opts, :certificate, "")),
      do: raise(ArgumentError, "SimpleStreams certificate must be one PEM certificate")

    case Catalog.architecture(opts[:architecture]) do
      {:ok, architecture} ->
        adapter = delta_adapter!(opts)

        %__MODULE__{
          connection: connection,
          context: context,
          architecture: architecture,
          delta_adapter: adapter,
          delta_config: opts[:delta_config],
          cache: cache!(connection, opts),
          certificate: Keyword.get(opts, :certificate, "")
        }

      _ ->
        raise ArgumentError, "Unsupported SimpleStreams architecture"
    end
  end

  def new!(_, _, _), do: raise(ArgumentError, "SimpleStreams requires explicit HTTPS")

  @doc "Native no-op disconnect; the immutable catalog owns no pool, files or conversion worker."
  def disconnect(%__MODULE__{}), do: :ok

  @doc "Native origin metadata without network or credential-file access; the certificate is the explicit `certificate:` PEM, never inferred from trust references."
  def connection_info(client) do
    with :ok <- authorize(client) do
      url = URI.to_string(client.connection.address)

      {:ok,
       %Discovery{
         certificate: client.certificate,
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

  defp certificate?(""), do: true

  defp certificate?(pem) when is_binary(pem) and byte_size(pem) <= 65_536 do
    match?([{:Certificate, _, :not_encrypted}], :public_key.pem_decode(pem))
  rescue
    _ -> false
  end

  defp certificate?(_), do: false

  # The pinned cache directory is namespaced by the hex SHA-256 of the stream URL.
  defp cache!(connection, opts) do
    case {opts[:cache_adapter], Keyword.has_key?(opts, :cache_config), opts[:cache_expiry]} do
      {nil, false, nil} ->
        nil

      {adapter, true, expiry}
      when is_atom(adapter) and not is_nil(adapter) and
             (is_nil(expiry) or (is_integer(expiry) and expiry > 0)) ->
        cache_adapter!(adapter)
        url = URI.to_string(connection.address)

        %{
          adapter: adapter,
          config: opts[:cache_config],
          expiry: expiry || @cache_expiry,
          namespace: :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
        }

      _ ->
        raise ArgumentError, "SimpleStreams cache requires explicit adapter configuration"
    end
  end

  defp cache_adapter!(adapter) do
    unless Code.ensure_loaded?(adapter) and function_exported?(adapter, :read, 3) and
             function_exported?(adapter, :write, 4) and
             function_exported?(adapter, :invalidate, 2),
           do: raise(ArgumentError, "SimpleStreams cache requires a complete host adapter")
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
    case lookup(client, fingerprint) do
      {:error, %Error{kind: :native, message: message} = error} ->
        {:error, %{error | message: "Failed getting image: " <> message}}

      other ->
        other
    end
  end

  # The pinned shared client's GetImage, which GetImageFile calls without a prefix.
  @doc false
  def lookup(client, fingerprint) do
    read(client, fn catalog ->
      case Enum.filter(catalog.images, &String.starts_with?(&1.data["fingerprint"], fingerprint)) do
        [image] -> {:ok, image}
        [] -> error(:native, "The requested image couldn't be found")
        _ -> error(:native, "More than one match for the provided partial fingerprint")
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
    with {:ok, image} <- lookup(client, fingerprint),
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

    with {:ok, index, bytes} <- stream(client, deadline),
         entries = index["index"] || %{},
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

  # The pinned parseStream and getImages wrapping.
  defp stream(client, deadline) do
    path = "streams/v1/index.json"

    with {:ok, body} <- cached_download(client, path, deadline),
         {:ok, index} <- decode(body, ~w(index format)) do
      {:ok, index, byte_size(body)}
    else
      {:error, %Error{kind: :native, message: message} = error} ->
        {:error, %{error | message: "Failed parsing stream: " <> message}}

      {:error, :decode, detail, body} ->
        error(
          :native,
          "Failed parsing stream: Failed decoding stream JSON from #{go_quote(url(client, "/" <> path))}: " <>
            "#{detail} (#{go_quote(body)})"
        )

      error ->
        error
    end
  end

  defp capacity(count, limit) when count <= limit, do: :ok
  defp capacity(_, _), do: error(:catalog_limit, nil)

  defp products(client, paths, deadline, bytes) do
    Enum.reduce_while(paths, {:ok, [], bytes, 0}, fn path, {:ok, acc, used, count} ->
      with {:ok, data, size} <- product_file(client, path, deadline),
           entries = data["products"] || %{},
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

  # The pinned parseProducts, which names the relative path and omits the body.
  defp product_file(client, path, deadline) do
    with true <- is_binary(path) or error(:invalid_path, nil),
         {:ok, body} <- cached_download(client, path, deadline),
         {:ok, data} <- decode(body, ~w(products)) do
      {:ok, data, byte_size(body)}
    else
      {:error, %Error{kind: :native, message: message} = error} ->
        {:error, %{error | message: "Failed parsing products: " <> message}}

      {:error, :decode, detail, _} ->
        error(
          :native,
          "Failed parsing products: Failed decoding products JSON from #{go_quote(path)}: #{detail}"
        )

      error ->
        error
    end
  end

  # The pinned cachedDownload: a fresh cache entry is used without a request; a
  # failed request or non-200 reply falls back to any cached entry, expired or not.
  defp cached_download(client, path, deadline) do
    name = path |> String.split("/") |> List.last()
    cached = cache_read(client, name)

    case cached do
      {body, false} ->
        {:ok, body}

      _ ->
        case fetch(client, path, deadline) do
          {:ok, 200, ""} ->
            error(:native, "No content in download from #{go_quote(url(client, path))}")

          {:ok, 200, body} ->
            cache_call(client, :write, [name, body])
            {:ok, body}

          {:ok, status, _} when is_nil(cached) ->
            error(:native, "Unable to fetch #{url(client, path)}: #{status_line(status)}")

          {:error, %Error{kind: :invalid_path}} = error ->
            error

          {:error, _} = error when is_nil(cached) ->
            error

          _ ->
            {:ok, elem(cached, 0)}
        end
    end
  end

  defp fetch(client, path, deadline) do
    with {:ok, path} <- path(path),
         true <- deadline > now() or error(:deadline, nil),
         connection = %{client.connection | timeout: max(1, deadline - now())},
         {:ok, response} <- Transport.request(connection, "GET", path, [], nil) do
      {:ok, response.status, response.body}
    end
  end

  defp decode(body, keys) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) ->
        if Enum.all?(keys, &(is_nil(data[&1]) or is_map(data[&1]) or &1 == "format")),
          do: {:ok, data},
          else: {:error, :decode, "cannot unmarshal into the pinned catalog type", body}

      {:ok, _} ->
        {:error, :decode, "cannot unmarshal into the pinned catalog type", body}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, :decode, Exception.message(error), body}
    end
  end

  defp cache_read(%{cache: nil}, _), do: nil

  defp cache_read(%{cache: cache} = client, name) do
    case cache_call(client, :read, [name]) do
      {:ok, body, age} when is_binary(body) and is_integer(age) and age >= 0 ->
        if byte_size(body) <= client.connection.max_response_bytes,
          do: {body, age > cache.expiry},
          else: nil

      _ ->
        nil
    end
  end

  # Cache failures are ignored as natively: a failed read is a miss and a failed
  # write or invalidation leaves the result unchanged.
  @doc false
  def cache_call(%{cache: nil}, _, _), do: :ok

  def cache_call(%{cache: cache}, function, args) do
    apply(cache.adapter, function, [cache.config, cache.namespace | args])
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc false
  def url(client, path),
    do: URI.to_string(client.connection.address) <> "/" <> String.trim_leading(path, "/")

  # Go's http.Response.Status for the standard reason phrase.
  @doc false
  def status_line(status),
    do: String.trim("#{status} #{StatusError.error(%StatusError{status: status})}")

  # Go strconv.Quote, as the pinned %q formats names and bodies.
  @doc false
  def go_quote(value), do: ~s(") <> quote_chars(value, []) <> ~s(")

  defp quote_chars(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp quote_chars(<<char::utf8, rest::binary>>, acc),
    do: quote_chars(rest, [escape(char) | acc])

  defp quote_chars(<<byte, rest::binary>>, acc),
    do: quote_chars(rest, ["\\x" <> hex(byte, 2) | acc])

  @escapes %{
    ?" => ~S(\"),
    ?\\ => ~S(\\),
    ?\a => ~S(\a),
    ?\b => ~S(\b),
    ?\f => ~S(\f),
    ?\n => ~S(\n),
    ?\r => ~S(\r),
    ?\t => ~S(\t),
    ?\v => ~S(\v)
  }

  defp escape(c) when is_map_key(@escapes, c), do: @escapes[c]
  defp escape(c) when c < 0x20 or c == 0x7F, do: "\\x" <> hex(c, 2)

  defp escape(c) when c in 0x80..0x9F or c in [0xAD, 0xFEFF] or c in 0x2028..0x2029,
    do: unicode(c)

  defp escape(c), do: <<c::utf8>>

  defp unicode(c) when c < 0x10000, do: "\\u" <> hex(c, 4)
  defp unicode(c), do: "\\U" <> hex(c, 8)

  defp hex(value, width),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

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
