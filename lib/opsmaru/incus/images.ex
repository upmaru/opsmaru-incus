defmodule Opsmaru.Incus.Images do
  @moduledoc "Native image transfers; host-owned sources/sinks and no mutation replay."
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Context, Error, ImageCopy, ImageSource, Model, OCI, Operation, Transfer}

  def import(client, image, metadata_source, opts \\ []) do
    with {:ok, model} <- Model.decode("ImagesPost", Model.encode(image)),
         :ok <- compression(client, model.data),
         {:ok, source, content_type} <- source(metadata_source, opts) do
      Transfer.upload(client, "/1.0/images", source, [
        {"content-type", content_type} | image_headers(model.data)
      ])
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  rescue
    _ -> {:error, %Error{kind: :invalid_image_arguments}}
  end

  @doc "Download a public or token-authorized private image to host-owned binary sinks."
  def download(client, fingerprint, sinks, opts \\ []) do
    with :ok <- download_arguments(fingerprint, sinks, opts) do
      ref = make_ref()
      secret = opts[:secret]

      # Match the pinned GetPrivateImageFile -> setQueryParam encoding exactly.
      query =
        if secret in [nil, ""],
          do: "",
          else:
            "?" <>
              URI.encode_query(
                secret: URI.encode_query(secret: secret) |> String.replace_prefix("secret=", "")
              )

      path = "/1.0/images/" <> escape(fingerprint) <> "/export" <> query
      handler = fn event -> image_event(event, ref, fingerprint, sinks) end
      Transfer.download_events(client, path, handler)
    end
  end

  defp download_arguments(fingerprint, sinks, opts) do
    if valid_fingerprint?(fingerprint) and valid_sinks?(sinks) and valid_download_options?(opts),
      do: :ok,
      else: {:error, %Error{kind: :invalid_image_arguments}}
  end

  defp valid_fingerprint?(value),
    do: is_binary(value) and byte_size(value) in 1..1024 and String.valid?(value)

  defp valid_sinks?(sinks),
    do:
      is_map(sinks) and map_size(sinks) in 1..2 and
        Enum.all?(sinks, fn {key, sink} ->
          key in [:metadata, :rootfs] and is_function(sink, 1)
        end)

  defp valid_download_options?(opts),
    do:
      Keyword.keyword?(opts) and length(opts) <= 1 and
        Enum.all?(opts, fn {key, value} ->
          key == :secret and is_binary(value) and byte_size(value) <= 8192 and
            String.valid?(value)
        end)

  def alias_type(client, image_type, name) do
    with {:ok, response} <- Incus.call(client, "GetImageAlias", %{"name" => name}) do
      data = response.metadata.data
      actual = if data["type"] in [nil, ""], do: "container", else: data["type"]

      cond do
        image_type == "" ->
          {:ok, response}

        image_type == actual ->
          {:ok,
           %{response | metadata: %{response.metadata | data: Map.put(data, "type", actual)}}}

        true ->
          {:error, %Error{kind: :alias_type_mismatch, response: response}}
      end
    end
  end

  def alias_architectures(client, image_type, name) do
    with {:ok, alias_response} <- alias_type(client, image_type, name),
         {:ok, image_response} <-
           Incus.call(client, "GetImage", %{
             "fingerprint" => alias_response.metadata.data["target"]
           }) do
      {:ok,
       %{
         image_response
         | metadata: %{image_response.metadata.data["architecture"] => alias_response.metadata}
       }}
    end
  end

  def image_secret(client, fingerprint) do
    with {:ok, token, response} <- secret_response(client, fingerprint) do
      {:ok, %{response | metadata: token}}
    end
  end

  defp secret_response(client, fingerprint) do
    with {:ok, response} <-
           Incus.call(client, "CreateImageSecret", %{"fingerprint" => fingerprint}) do
      token = token_secret(response)

      if is_binary(token),
        do: {:ok, token, response},
        else:
          {:error, %Error{kind: :uncertain, response: response, operation: response.operation}}
    end
  end

  defp token_secret(response) do
    metadata = response.metadata.data["metadata"]
    if is_map(metadata), do: metadata["secret"]
  end

  @copy_options [
    :mode,
    :approved_origin,
    :aliases,
    :copy_aliases,
    :public,
    :auto_update,
    :profiles,
    :type,
    :relay,
    :registry_credentials
  ]

  @doc """
  Copy using one explicit approved connection per side; no address fallback or replay.

  Returns the accepted native handles as an `ImageCopy` without waiting or cleanup;
  `wait_copy/2` completes it. Pull and push need `:approved_origin`, the HTTPS origin
  of the side the other backend connects to. A failure keeps every accepted handle in
  `response.accepted` and cancels none.

  The source may be a resolved `OCI` value, as the pinned `CopyImage` takes a
  `ProtocolOCI` source. A pull hands the target protocol `oci` and the registry
  certificate; `:registry_credentials` (`{username, password}`, password `nil` for
  a username-only URL) adds Go's escaped user information to the server URL for a
  private registry. A relay converts through the host adapter. A push fails like
  Go: the target's push token is requested and, after the native error, cancelled.
  """
  def copy(target, source, image, opts \\ []) do
    with :ok <- Context.authorize(target.context, target.connection),
         :ok <- Context.authorize(source.context, source.connection),
         :ok <- copy_options(opts),
         :ok <- registry_credentials(source, opts),
         false <- same_backend?(target, source),
         {:ok, image} <- Model.decode("Image", Model.encode(image)),
         aliases = copy_aliases(image.data, opts),
         :ok <- check_aliases(aliases),
         :ok <- profile_override(target, opts) do
      image = image.data

      result =
        case opts[:mode] || "pull" do
          "pull" ->
            with {:ok, url} <- copy_origin(source, opts[:approved_origin]),
                 do: pull(target, source, image, aliases, url, opts)

          "push" ->
            with :ok <- push_source(source),
                 {:ok, url} <- copy_origin(target, opts[:approved_origin]),
                 do: push(target, source, image, aliases, url, opts)

          "relay" ->
            relay(target, source, image, aliases, opts)
        end

      with {:error, kind} when is_atom(kind) <- result, do: {:error, %Error{kind: kind}}
    else
      true -> {:error, %Error{kind: :same_backend}}
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp copy_options(opts) do
    cond do
      not (Keyword.keyword?(opts) and Keyword.keys(opts) -- @copy_options == [] and
               length(opts) == length(Enum.uniq(Keyword.keys(opts)))) ->
        {:error, :invalid_copy_options}

      opts[:mode] not in [nil, "pull", "push", "relay"] ->
        {:error, :unsupported_copy_mode}

      not valid_copy_values?(opts) ->
        {:error, :invalid_copy_options}

      # Credentials ride only the server URL of a daemon pull; a relay's adapter has its own.
      not is_nil(opts[:registry_credentials]) and opts[:mode] not in [nil, "pull"] ->
        {:error, :invalid_copy_options}

      true ->
        :ok
    end
  end

  defp valid_copy_values?(opts),
    do:
      Enum.all?([:public, :auto_update, :copy_aliases], &(opts[&1] in [nil, true, false])) and
        (is_nil(opts[:type]) or text?(opts[:type], 0)) and
        (is_nil(opts[:approved_origin]) or text?(opts[:approved_origin], 1)) and
        (is_nil(opts[:profiles]) or
           (is_list(opts[:profiles]) and Enum.all?(opts[:profiles], &text?(&1, 1)))) and
        ImageSource.credentials?(opts[:registry_credentials])

  # Every alias is checked before any request, so bad input never strands a handle.
  defp check_aliases(nil), do: :ok

  defp check_aliases(aliases) do
    if is_list(aliases) and
         Enum.all?(aliases, fn entry ->
           is_map(entry) and text?(entry["name"], 1) and
             (is_nil(entry["description"]) or text?(entry["description"], 0))
         end),
       do: :ok,
       else: {:error, :invalid_copy_options}
  end

  defp text?(value, min),
    do: is_binary(value) and byte_size(value) in min..1024 and String.valid?(value)

  defp same_backend?(one, two),
    do:
      one.connection.transport == two.connection.transport and
        one.connection.address == two.connection.address and
        one.connection.project == two.connection.project and
        one.connection.member == two.connection.member

  defp profile_override(target, opts) do
    if is_nil(opts[:profiles]),
      do: :ok,
      else: Incus.require_extension(target, "image_copy_profile")
  end

  # As in the pinned client: the explicit aliases, or the image's own followed by them.
  defp copy_aliases(image, opts) do
    if opts[:copy_aliases] == true,
      do: append(image["aliases"], opts[:aliases]),
      else: opts[:aliases]
  end

  defp append(base, nil), do: base
  defp append(base, more), do: (base || []) ++ more

  # The other backend connects to exactly the origin the host approved for this side.
  defp copy_origin(client, approved) do
    if client.connection.transport == :https and is_binary(approved) and
         approved == URI.to_string(client.connection.address),
       do: {:ok, approved},
       else: {:error, :unapproved_copy_origin}
  end

  # Registry credentials describe an OCI registry; an Incus source has none.
  defp registry_credentials(source, opts) do
    if is_nil(opts[:registry_credentials]) or ImageSource.oci?(source),
      do: :ok,
      else: {:error, :invalid_copy_options}
  end

  # The pinned CopyImage has no push check of its own; ExportImage on an Incus source does.
  defp push_source(source) do
    if ImageSource.oci?(source),
      do: :ok,
      else: Incus.require_extension(source, "images_push_relay")
  end

  defp pull(target, source, image, aliases, url, opts) do
    with {:ok, secret, copy} <- pull_secret(source, image) do
      body = %{
        "aliases" => aliases,
        "auto_update" => opts[:auto_update] == true,
        "public" => opts[:public] == true,
        "profiles" => opts[:profiles],
        "source" => %{
          "type" => "image",
          "mode" => "pull",
          "protocol" => ImageSource.protocol(source),
          "server" => ImageSource.server(url, opts[:registry_credentials]),
          "certificate" => ImageSource.certificate(source),
          "project" => ImageSource.project(source),
          "fingerprint" => image["fingerprint"],
          "secret" => secret,
          "image_type" => opts[:type] || ""
        }
      }

      # Servers without image_create_aliases get the aliases after the copy, as natively.
      later = if Incus.has_extension?(target, "image_create_aliases"), do: [], else: aliases
      accept(%{copy | aliases: names(later)}, :target, target, "CreateImage", %{}, body)
    end
  end

  # The secret operation is bound before its secret is read, so it is never lost.
  defp pull_secret(source, image) do
    copy = %ImageCopy{mode: "pull"}

    if image["public"] == true do
      {:ok, nil, copy}
    else
      args = %{"fingerprint" => image["fingerprint"]}

      with :ok <- ImageSource.private_image(source),
           {:ok, copy} <- accept(copy, :source, source, "CreateImageSecret", args, nil) do
        case token_secret(copy.source.response) do
          secret when is_binary(secret) -> {:ok, secret, copy}
          _ -> unread_secret(copy, :source)
        end
      end
    end
  end

  # An accepted operation without a usable secret may have been accepted all the same.
  defp unread_secret(copy, side) do
    operation = Map.fetch!(copy, side)

    copy_failure(copy, %Error{
      kind: :uncertain,
      response: operation.response,
      operation: operation.url
    })
  end

  defp push(target, source, image, aliases, url, opts) do
    # The token request carries no profiles or auto_update, as natively; the export does.
    body = %{
      "aliases" => aliases,
      "expires_at" => image["expires_at"],
      "properties" => image["properties"],
      "public" => opts[:public] == true,
      "source" => %{"mode" => "push", "fingerprint" => image["fingerprint"]}
    }

    with {:ok, copy} <-
           accept(%ImageCopy{mode: "push"}, :target, target, "CreateImage", %{}, body) do
      case token_secret(copy.target.response) do
        secret when is_binary(secret) and is_struct(source, OCI) ->
          # As natively: the OCI export fails, then the token is cancelled.
          _ = Operation.cancel(copy.target)
          {:error, error} = OCI.unsupported(source, "ExportImage")
          copy_failure(copy, error)

        secret when is_binary(secret) ->
          export = %{
            "target" => url,
            "certificate" => ImageSource.certificate(target),
            "secret" => secret,
            "project" => target.connection.project || "default",
            "profiles" => opts[:profiles]
          }

          # A failed export keeps the token handle; the host cancels it explicitly.
          accept(
            copy,
            :source,
            source,
            "ExportImage",
            %{"fingerprint" => image["fingerprint"]},
            export
          )

        _ ->
          unread_secret(copy, :target)
      end
    end
  end

  defp accept(copy, side, client, method, args, body) do
    with {:ok, response} <- Incus.call(client, method, args, body: body),
         {:ok, operation} <- bind(client, response) do
      {:ok, Map.put(copy, side, operation)}
    else
      {:error, error} -> copy_failure(copy, error)
    end
  end

  # A reply that does not bind as an accepted operation may still have been accepted.
  defp bind(client, response) do
    case Operation.from_response(client, response) do
      {:ok, operation} -> {:ok, operation}
      {:error, error} -> {:error, %{error | kind: :uncertain}}
    end
  end

  defp copy_failure(copy, %Error{} = error),
    do: {:error, %{error | response: %{accepted: copy, error: error}}}

  defp copy_failure(copy, kind), do: copy_failure(copy, %Error{kind: kind})

  defp names(nil), do: []
  defp names(aliases), do: Enum.map(aliases, & &1["name"])

  defp relay(target, source, image, aliases, opts) do
    # The host provides staging sinks and rewindable source factories. No fixed
    # state directory, tempfile generation, deletion or host CLI is introduced.
    adapter = opts[:relay]

    if is_map(adapter) and is_function(adapter[:metadata_sink], 1) and
         is_function(adapter[:metadata_source], 0) do
      sinks = %{metadata: adapter[:metadata_sink]}

      sinks =
        if is_function(adapter[:rootfs_sink], 1),
          do: Map.put(sinks, :rootfs, adapter[:rootfs_sink]),
          else: sinks

      # As natively: public, profiles and aliases; the aliases are applied again after.
      body = %{
        "public" => opts[:public] == true,
        "profiles" => opts[:profiles],
        "aliases" => aliases
      }

      copy = %ImageCopy{
        mode: "relay",
        aliases: names(aliases),
        fingerprint: image["fingerprint"]
      }

      with {:ok, transfer} <- relay_download(copy, source, image, sinks),
           {:ok, upload_opts} <- relay_upload_options(adapter, image, transfer.result),
           do: relay_upload(copy, target, body, adapter[:metadata_source].(), upload_opts)
    else
      {:error, %Error{kind: :missing_relay_adapter}}
    end
  end

  defp relay_download(_copy, %OCI{}, _image, sinks) when not is_map_key(sinks, :rootfs),
    do: {:error, %Error{kind: :missing_relay_adapter}}

  defp relay_download(copy, %OCI{} = source, image, sinks) do
    # The pinned conversion always yields both parts, so the upload is split.
    case OCI.image_file(source, image["fingerprint"], sinks) do
      {:ok, _} -> {:ok, %{result: %{names: %{metadata: "", rootfs: ""}}}}
      {:error, error} -> copy_failure(copy, error)
    end
  end

  defp relay_download(copy, source, image, sinks) do
    with {:error, error} <- download(source, image["fingerprint"], sinks),
         do: copy_failure(copy, error)
  end

  defp relay_upload(copy, target, body, metadata, opts) do
    with {:ok, response} <- import(target, body, metadata, opts),
         {:ok, operation} <- bind(target, response) do
      {:ok, %{copy | target: operation}}
    else
      {:error, error} -> copy_failure(copy, error)
    end
  end

  defp relay_upload_options(adapter, image, result) do
    # The pinned relay names both parts after the image filename, empty when unset.
    name = image["filename"] || ""
    opts = [metadata_name: name]

    # Part presence distinguishes a split export even when rootfs is empty.
    # A saved rootfs must never become a metadata-only target mutation.
    if Map.has_key?(result.names, :rootfs) do
      with true <- is_function(adapter[:rootfs_source], 0),
           rootfs <- adapter[:rootfs_source].(),
           true <- not is_nil(Enumerable.impl_for(rootfs)) do
        {:ok, Keyword.merge(opts, rootfs: rootfs, rootfs_name: name, type: image["type"])}
      else
        _ -> {:error, %Error{kind: :missing_relay_adapter}}
      end
    else
      {:ok, opts}
    end
  rescue
    _ -> {:error, %Error{kind: :missing_relay_adapter}}
  catch
    _, _ -> {:error, %Error{kind: :missing_relay_adapter}}
  end

  @doc """
  Wait for the operation that drives a copy, then perform the pinned cleanup.

  The target drives pull and relay copies and the source export drives a push. Once
  a push export reaches a final state, the target's token is cancelled, as natively.
  Once a pull (against a server without `image_create_aliases`) or relay succeeds,
  the requested aliases are created, as natively. A local deadline or read failure
  performs no cleanup, so the copy may still run. Errors keep every handle in
  `response.accepted`; nothing is replayed. Each alias is sent at most once: the
  returned copy keeps only aliases never sent, and an alias failure names its alias
  in `response.alias`, so waiting again never resends one.
  """
  def wait_copy(copy, opts \\ [])

  def wait_copy(%ImageCopy{mode: mode} = copy, opts) when mode in ["pull", "push", "relay"] do
    side = if mode == "push", do: :source, else: :target

    with true <-
           Keyword.keyword?(opts) and Keyword.keys(opts) -- [:timeout, :poll_interval] == [],
         %Operation{} = operation <- Map.fetch!(copy, side) do
      case Operation.wait(operation, opts) do
        {:ok, current} ->
          copy |> Map.put(side, current) |> cancel_token() |> create_aliases()

        {:error, %Error{kind: :operation_failed} = error} ->
          copy_failure(cancel_token(copy), error)

        {:error, error} ->
          copy_failure(copy, error)
      end
    else
      false -> copy_failure(copy, :invalid_deadline)
      _ -> copy_failure(copy, :invalid_copy)
    end
  end

  def wait_copy(copy, _opts), do: copy_failure(copy, :invalid_copy)

  # The pinned push ignores the token cancellation's result; the handle is kept.
  defp cancel_token(%ImageCopy{mode: "push", target: %Operation{} = token} = copy) do
    case Operation.cancel(token) do
      {:ok, current} -> %{copy | target: current}
      {:error, _} -> copy
    end
  end

  defp cancel_token(copy), do: copy

  defp create_aliases(%ImageCopy{aliases: []} = copy), do: {:ok, copy}

  defp create_aliases(%ImageCopy{target: target} = copy) do
    metadata = Operation.data(target)["metadata"]
    fingerprint = copy.fingerprint || (is_map(metadata) && metadata["fingerprint"])

    if is_binary(fingerprint),
      do: create_alias(copy, fingerprint, copy.aliases),
      else: copy_failure(copy, :invalid_copy_fingerprint)
  end

  # Each alias is sent at most once: a returned copy keeps only the aliases never sent,
  # and a failure names the alias whose reply it reports.
  defp create_alias(copy, _fingerprint, []), do: {:ok, %{copy | aliases: []}}

  defp create_alias(copy, fingerprint, [name | rest]) do
    case Incus.call(copy.target.client, "CreateImageAlias", %{},
           body: %{"name" => name, "target" => fingerprint}
         ) do
      {:ok, _} ->
        create_alias(copy, fingerprint, rest)

      {:error, error} ->
        {:error,
         %{error | response: %{accepted: %{copy | aliases: rest}, error: error, alias: name}}}
    end
  end

  defp compression(client, data) do
    if data["compression_algorithm"] in [nil, ""],
      do: :ok,
      else: Incus.require_extension(client, "image_compression_algorithm")
  end

  defp source(metadata, opts) do
    if opts[:rootfs] do
      boundary = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      meta_name = filename!(opts[:metadata_name] || "metadata.tar")
      root_name = filename!(opts[:rootfs_name] || "rootfs.tar")
      kind = if opts[:type] == "virtual-machine", do: "rootfs.img", else: "rootfs"

      header = fn name, filename ->
        [
          {"content-disposition",
           "form-data; name=\"#{name}\"; filename=\"#{quote_name(filename)}\""},
          {"content-type", "application/octet-stream"}
        ]
      end

      chunks =
        Stream.concat([
          [
            IO.iodata_to_binary(
              :cow_multipart.first_part(boundary, header.("metadata", meta_name))
            )
          ],
          metadata,
          [IO.iodata_to_binary(:cow_multipart.part(boundary, header.(kind, root_name)))],
          opts[:rootfs],
          [IO.iodata_to_binary(:cow_multipart.close(boundary))]
        ])

      {:ok, chunks, "multipart/form-data; boundary=" <> boundary}
    else
      {:ok, metadata, "application/octet-stream"}
    end
  end

  defp image_headers(image) do
    headers = if image["public"] == true, do: [{"x-incus-public", "true"}], else: []

    headers =
      if image["filename"] in [nil, ""],
        do: headers,
        else: [{"x-incus-filename", image["filename"]} | headers]

    headers =
      if image["properties"] in [nil, %{}],
        do: headers,
        else: [
          {"x-incus-properties", image["properties"] |> Enum.sort() |> URI.encode_query()}
          | headers
        ]

    headers =
      if image["profiles"] in [nil, []],
        do: headers,
        else: [
          {"x-incus-profiles", URI.encode_query(Enum.map(image["profiles"], &{"profile", &1}))}
          | headers
        ]

    headers =
      if image["aliases"] in [nil, []],
        do: headers,
        else: [
          {"x-incus-aliases",
           URI.encode_query(Enum.map(image["aliases"], &{"alias", &1["name"]}))}
          | headers
        ]

    source = image["source"] || %{}

    if source["mode"] == "push" and source["fingerprint"] not in [nil, ""] and
         source["secret"] not in [nil, ""],
       do: [
         {"x-incus-fingerprint", source["fingerprint"]},
         {"x-incus-secret", source["secret"]} | headers
       ],
       else: headers
  end

  defp image_event({:headers, headers}, ref, _fingerprint, sinks) do
    {type, subtype, _} =
      :cow_http_hd.parse_content_type(headers["content-type"] || "application/octet-stream")

    # As in the pinned client, a split export needs both sinks before any byte is written.
    if {type, subtype} == {"multipart", "form-data"} and not Map.has_key?(sinks, :rootfs),
      do: {:error, :missing_sink},
      else: image_headers(headers, ref)
  rescue
    _ -> {:error, :invalid_image_headers}
  end

  defp image_event({:data, bytes}, ref, _, sinks), do: image_data(bytes, ref, sinks)

  defp image_event(:done, ref, fingerprint, _) do
    state = Process.get(ref)
    digest = Base.encode16(:crypto.hash_final(state.hash), case: :lower)

    cond do
      state.mode == :multipart and (state.phase != :done or state.parts != [:metadata, :rootfs]) ->
        {:error, :invalid_image_stream}

      not state.oci and not String.starts_with?(digest, fingerprint) ->
        {:error, :fingerprint_mismatch}

      true ->
        {:ok, %{names: state.names, sizes: state.sizes, sha256: digest}}
    end
  end

  defp image_headers(headers, ref) do
    if is_nil(Process.get(ref)) do
      {type, subtype, params} =
        :cow_http_hd.parse_content_type(headers["content-type"] || "application/octet-stream")

      mode = if {type, subtype} == {"multipart", "form-data"}, do: :multipart, else: :unified
      name = image_name(mode, headers)

      state = %{
        mode: mode,
        boundary: List.keyfind(params, "boundary", 0),
        phase: :headers,
        buffer: "",
        parts: [],
        current: if(mode == :unified, do: :metadata, else: nil),
        names: if(name, do: %{metadata: name}, else: %{}),
        sizes: %{metadata: 0, rootfs: 0},
        hash: :crypto.hash_init(:sha256),
        oci: headers["x-incus-type"] == "oci"
      }

      state = if mode == :multipart, do: %{state | boundary: elem(state.boundary, 1)}, else: state

      if mode == :multipart and byte_size(state.boundary) not in 1..200,
        do: raise("invalid multipart boundary")

      Process.put(ref, state)
    end

    :ok
  end

  defp image_data(bytes, ref, sinks) do
    state = Process.get(ref)

    case consume(state, bytes, sinks) do
      {:ok, state} ->
        Process.put(ref, state)
        :ok

      error ->
        error
    end
  rescue
    _ -> {:error, :invalid_image_stream}
  end

  defp image_name(:multipart, _), do: nil

  defp image_name(:unified, headers) do
    {_kind, params} =
      :cow_multipart.parse_content_disposition(headers["content-disposition"] || "")

    case List.keyfind(params, "filename", 0) do
      {_, filename} -> filename
      nil -> raise("missing native image filename")
    end
  end

  defp consume(%{mode: :unified} = state, bytes, sinks), do: write(state, bytes, sinks)

  defp consume(%{phase: :done} = state, bytes, _sinks) do
    if String.trim(bytes) == "", do: {:ok, state}, else: {:error, :invalid_image_stream}
  end

  defp consume(%{phase: :headers} = state, bytes, sinks) do
    buffer = state.buffer <> bytes

    case :cow_multipart.parse_headers(buffer, state.boundary) do
      :more ->
        if byte_size(buffer) <= 65_536,
          do: {:ok, %{state | buffer: buffer}},
          else: {:error, :image_headers_limit}

      {:more, rest} ->
        if byte_size(rest) <= 65_536,
          do: {:ok, %{state | buffer: rest}},
          else: {:error, :image_headers_limit}

      {:done, rest} ->
        consume(%{state | phase: :done, buffer: ""}, rest, sinks)

      {:ok, headers, rest} ->
        {_kind, params} =
          :cow_multipart.parse_content_disposition(
            List.keyfind(headers, "content-disposition", 0)
            |> elem(1)
          )

        name = List.keyfind(params, "name", 0) |> elem(1)
        filename = List.keyfind(params, "filename", 0) |> elem(1)

        kind =
          case name do
            "metadata" -> :metadata
            root when root in ["rootfs", "rootfs.img"] -> :rootfs
          end

        parts = state.parts ++ [kind]

        if parts not in [[:metadata], [:metadata, :rootfs]],
          do: raise("invalid part ordering")

        consume(
          %{
            state
            | phase: :body,
              buffer: "",
              current: kind,
              parts: state.parts ++ [kind],
              names: Map.put(state.names, kind, filename)
          },
          rest,
          sinks
        )
    end
  end

  defp consume(%{phase: :body} = state, bytes, sinks) do
    case :cow_multipart.parse_body(state.buffer <> bytes, state.boundary) do
      {:ok, body} ->
        write(%{state | buffer: ""}, body, sinks)

      {:ok, body, rest} ->
        write(%{state | buffer: rest}, body, sinks)

      {:done, body, rest} ->
        with {:ok, state} <- write(%{state | phase: :headers, buffer: ""}, body, sinks),
             do: consume(state, rest, sinks)

      {:done, body} ->
        write(%{state | phase: :headers, buffer: ""}, body, sinks)

      :done ->
        consume(%{state | phase: :headers}, state.buffer <> bytes, sinks)
    end
  end

  defp write(state, bytes, sinks) do
    case Map.fetch(sinks, state.current) do
      {:ok, sink} when is_function(sink, 1) ->
        if sink.(bytes) == :ok,
          do:
            {:ok,
             %{
               state
               | hash: :crypto.hash_update(state.hash, bytes),
                 sizes: Map.update!(state.sizes, state.current, &(&1 + byte_size(bytes)))
             }},
          else: {:error, :sink_failed}

      _ ->
        {:error, :missing_sink}
    end
  end

  defp escape(value), do: URI.encode(value, &(URI.char_unreserved?(&1) or &1 in ~c"$&+:=@"))

  defp filename!(value) do
    if is_binary(value) and byte_size(value) in 0..1024 and
         not String.contains?(value, ["\r", "\n", <<0>>]),
       do: value,
       else: raise("invalid native filename")
  end

  defp quote_name(value),
    do: value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end
