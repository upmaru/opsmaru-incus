defmodule Opsmaru.Incus.Images do
  @moduledoc "Native image transfers; host-owned sources/sinks and no mutation replay."
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Error, Model, Transfer}

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
    with {:ok, response} <-
           Incus.call(client, "CreateImageSecret", %{"fingerprint" => fingerprint}),
         token when is_binary(token) <- get_in(response.metadata.data, ["metadata", "secret"]) do
      {:ok, %{response | metadata: token}}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, %Error{kind: :invalid_copy_secret}}
    end
  end

  @doc "Copy using one explicit approved connection per side; no address fallback or replay."
  def copy(target, source, image, opts \\ []) do
    with :ok <- Opsmaru.Context.authorize(target.context, target.connection),
         :ok <- Opsmaru.Context.authorize(source.context, source.connection),
         false <- same_backend?(target, source),
         {:ok, image} <- Model.decode("Image", Model.encode(image)),
         :ok <- profile_override(target, opts) do
      body = copy_body(image.data, opts)

      case opts[:mode] || "pull" do
        "pull" -> pull(target, source, image.data, body, opts)
        "push" -> push(target, source, image.data, body)
        "relay" -> relay(target, source, image.data, body, opts)
        _ -> {:error, %Error{kind: :unsupported_copy_mode}}
      end
    else
      true -> {:error, %Error{kind: :same_backend}}
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp same_backend?(one, two),
    do:
      one.connection.transport == two.connection.transport and
        one.connection.address == two.connection.address and
        one.connection.project == two.connection.project and
        one.connection.member == two.connection.member

  defp profile_override(target, opts) do
    if Keyword.has_key?(opts, :profiles),
      do: Incus.require_extension(target, "image_copy_profile"),
      else: :ok
  end

  defp copy_body(image, opts) do
    aliases =
      if opts[:copy_aliases],
        do: (image["aliases"] || []) ++ (opts[:aliases] || []),
        else: opts[:aliases] || []

    %{
      "public" => opts[:public] == true,
      "auto_update" => opts[:auto_update] == true,
      "aliases" => aliases,
      "profiles" => opts[:profiles]
    }
  end

  defp origin(%{connection: %{transport: :https, address: uri}}), do: {:ok, URI.to_string(uri)}
  defp origin(_), do: {:error, %Error{kind: :unreachable_copy_origin}}
  defp certificate(client), do: (client.server.environment || %{})["certificate"] || ""

  defp secret(source, image) do
    if image["public"] == true do
      {:ok, nil, nil}
    else
      with {:ok, response} <-
             Incus.call(source, "CreateImageSecret", %{"fingerprint" => image["fingerprint"]}),
           token when is_binary(token) <- get_in(response.metadata.data, ["metadata", "secret"]) do
        {:ok, token, response}
      else
        {:error, error} -> {:error, error}
        _ -> {:error, %Error{kind: :invalid_copy_secret}}
      end
    end
  end

  defp pull(target, source, image, body, opts) do
    with {:ok, url} <- origin(source), {:ok, secret, source_operation} <- secret(source, image) do
      body =
        Map.put(body, "source", %{
          "type" => "image",
          "mode" => "pull",
          "protocol" => "incus",
          "server" => url,
          "certificate" => certificate(source),
          "project" => source.connection.project || "default",
          "fingerprint" => image["fingerprint"],
          "secret" => secret,
          "image_type" => opts[:type] || ""
        })

      case Incus.call(target, "CreateImage", %{}, body: body) do
        {:ok, accepted} ->
          {:ok, %{source: source_operation, target: accepted, state: :accepted}}

        {:error, error} ->
          {:error,
           %Error{
             kind: :copy_failed,
             response: %{source: source_operation, error: error},
             operation: if(source_operation, do: source_operation.operation)
           }}
      end
    end
  end

  defp push(target, source, image, body) do
    with :ok <- Incus.require_extension(source, "images_push_relay"),
         {:ok, url} <- origin(target),
         {:ok, token} <-
           Incus.call(target, "CreateImage", %{},
             body:
               Map.merge(body, %{
                 "properties" => image["properties"],
                 "expires_at" => image["expires_at"],
                 "source" => %{
                   "mode" => "push",
                   "fingerprint" => image["fingerprint"],
                   "server" => "",
                   "certificate" => "",
                   "project" => "",
                   "type" => ""
                 }
               })
           ) do
      secret = get_in(token.metadata.data, ["metadata", "secret"])

      if is_binary(secret) do
        case Incus.call(source, "ExportImage", %{"fingerprint" => image["fingerprint"]},
               body: %{
                 "target" => url,
                 "certificate" => certificate(target),
                 "secret" => secret,
                 "project" => target.connection.project || "default",
                 "profiles" => body["profiles"]
               }
             ) do
          {:ok, exported} ->
            {:ok, %{source: exported, target: token, state: :accepted}}

          {:error, error} ->
            {:error,
             %Error{
               kind: :copy_failed,
               response: %{target: token, error: error},
               operation: token.operation
             }}
        end
      else
        {:error, %Error{kind: :invalid_copy_secret, response: token, operation: token.operation}}
      end
    end
  end

  defp relay(target, source, image, body, opts) do
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

      with {:ok, transfer} <- download(source, image["fingerprint"], sinks) do
        upload_opts = [metadata_name: image["filename"] || transfer.result.names.metadata]

        upload_opts =
          if transfer.result.sizes.rootfs > 0 and is_function(adapter[:rootfs_source], 0),
            do:
              Keyword.merge(upload_opts,
                rootfs: adapter[:rootfs_source].(),
                rootfs_name: image["filename"] || transfer.result.names.rootfs,
                type: image["type"]
              ),
            else: upload_opts

        import(target, body, adapter[:metadata_source].(), upload_opts)
      end
    else
      {:error, %Error{kind: :missing_relay_adapter}}
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

  defp image_event({:headers, headers}, ref, _fingerprint, _sinks) do
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
  rescue
    _ -> {:error, :invalid_image_headers}
  end

  defp image_event({:data, bytes}, ref, _, sinks) do
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
    if is_binary(value) and byte_size(value) in 1..1024 and
         not String.contains?(value, ["\r", "\n", <<0>>]),
       do: value,
       else: raise("invalid native filename")
  end

  defp quote_name(value),
    do: value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end
