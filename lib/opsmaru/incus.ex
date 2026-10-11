defmodule Opsmaru.Incus do
  @moduledoc """
  Explicit native Incus client, independent of application startup and SQL.

  `connect/2` performs discovery; constructing Connection/Context does no I/O.
  Every call checks the host binding/readiness. `raw_query/5` retains native
  envelope metadata, error values and ETags; it is an explicit low-level call,
  not evidence of typed method parity. No mutations are automatically retried.
  """
  alias Opsmaru.Context
  alias Opsmaru.Incus.{Connection, Error, Response, Server, Transport}
  @enforce_keys [:connection, :context, :server]
  defstruct [:connection, :context, :server]
  @type t :: %__MODULE__{}

  @doc "Invoke an implemented native method by its reference name; missing methods fail explicitly."
  def call(client, method, arguments \\ %{}, opts \\ [])

  def call(client, "GetImageAliasType", %{"image_type" => type, "name" => name}, []),
    do: Opsmaru.Incus.Images.alias_type(client, type, name)

  def call(client, "GetImageAliasArchitectures", %{"image_type" => type, "name" => name}, []),
    do: Opsmaru.Incus.Images.alias_architectures(client, type, name)

  def call(client, "GetImageSecret", %{"fingerprint" => fingerprint}, []),
    do: Opsmaru.Incus.Images.image_secret(client, fingerprint)

  def call(client, method, arguments, opts),
    do: Opsmaru.Incus.API.call(client, method, arguments, opts)

  @doc "List implemented native method names. This is not a full-parity claim."
  def methods,
    do:
      Enum.sort(
        Opsmaru.Incus.API.methods() ++
          ["GetImageAliasType", "GetImageAliasArchitectures", "GetImageSecret"]
      )

  @doc "Download a native ACL log to a bounded acknowledged binary sink."
  def network_acl_log(client, name, sink) do
    with :ok <- require_extension(client, "network_acl_log"),
         do:
           Opsmaru.Incus.Transfer.download(
             client,
             "/1.0/network-acls/" <> URI.encode(name, &URI.char_unreserved?/1) <> "/log",
             sink
           )
  end

  @doc "Open the native SFTP byte connection; the caller supplies its SFTP implementation."
  def sftp(client, instance) do
    with :ok <- upgrade_segments([instance]) do
      Opsmaru.Incus.RawChannel.open(
        client,
        "/1.0/instances/" <> path_escape(instance) <> "/sftp",
        "sftp"
      )
    end
  end

  @doc "Open the native NBD byte connection after checking the native extension."
  def nbd(client, instance, opts \\ []) do
    with :ok <- upgrade_segments([instance]),
         :ok <- upgrade_options(opts, :reuse),
         :ok <- require_extension(client, "instance_nbd") do
      path =
        "/1.0/instances/" <>
          path_escape(instance) <>
          "/nbd" <>
          if(opts[:reuse] == true, do: "?reuse=1", else: "")

      Opsmaru.Incus.RawChannel.open(client, path, "nbd")
    end
  end

  @doc "Open a native volume SFTP byte channel; protocol handling remains caller-owned."
  def volume_sftp(client, pool, type, name) do
    with :ok <- upgrade_segments([pool, type, name]),
         :ok <- require_extension(client, "custom_volume_sftp") do
      Opsmaru.Incus.RawChannel.open(client, volume_path(pool, type, name) <> "/sftp", "sftp")
    end
  end

  @doc "Open a native volume NBD byte channel, optionally requesting writable access."
  def volume_nbd(client, pool, type, name, opts \\ []) do
    with :ok <- upgrade_segments([pool, type, name]),
         :ok <- upgrade_options(opts, :writable),
         :ok <- require_extension(client, "storage_volume_nbd") do
      Opsmaru.Incus.RawChannel.open(
        client,
        volume_path(pool, type, name) <>
          "/nbd" <> if(opts[:writable] == true, do: "?writable=1", else: ""),
        "nbd"
      )
    end
  end

  defp volume_path(pool, type, name),
    do:
      "/1.0/storage-pools/" <>
        path_escape(pool) <>
        "/volumes/" <>
        path_escape(type) <> "/" <> path_escape(name)

  # The unchanged Go helpers use url.PathEscape, preserving these path characters.
  defp path_escape(value),
    do: URI.encode(value, &(URI.char_unreserved?(&1) or &1 in ~c"$&+:=@"))

  defp upgrade_segments(values) do
    if Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..1024 and String.valid?(&1))),
      do: :ok,
      else: {:error, %Error{kind: :invalid_arguments}}
  end

  defp upgrade_options(opts, key) do
    if Keyword.keyword?(opts) and length(opts) <= 1 and
         Enum.all?(opts, fn {name, value} -> name == key and is_boolean(value) end),
       do: :ok,
       else: {:error, %Error{kind: :invalid_arguments}}
  end

  def connect(%Connection{} = connection, %Context{} = context) do
    with {:ok, response} <- raw_query(connection, context, "GET", "/1.0", []),
         {:ok, server} <- Server.decode(response.metadata),
         :ok <- compatible_version(server) do
      {:ok, %__MODULE__{connection: connection, context: context, server: server}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp compatible_version(%Server{api_version: "1.0"}), do: :ok
  defp compatible_version(_), do: {:error, :unsupported_version}

  def has_extension?(%__MODULE__{server: server}, extension),
    do: extension in server.api_extensions

  def require_extension(client, extension) do
    if has_extension?(client, extension),
      do: :ok,
      else: {:error, %Error{kind: :unsupported_extension, extension: extension}}
  end

  def project(client, project),
    do: %{client | connection: Connection.project(client.connection, project)}

  def member(client, member),
    do: %{client | connection: Connection.member(client.connection, member)}

  def raw_query(%__MODULE__{} = client, method, path), do: raw_query(client, method, path, [])

  def raw_query(%__MODULE__{} = client, method, path, opts),
    do: raw_query(client.connection, client.context, method, path, opts)

  def raw_query(connection, context, method, path, opts) do
    with :ok <- Context.authorize(context, connection),
         {:ok, path} <- request_path(connection, path),
         {:ok, body, headers} <- request_body(connection, method, opts),
         {:ok, wire} <- Transport.request(connection, method, path, headers, body),
         {:ok, response} <- Response.decode(wire.body, wire.status, wire.headers) do
      response = %{response | connection: connection, identity: context.identity}

      if response.type == "error" or wire.status >= 400 do
        {:error,
         %Error{
           kind: :native,
           http_status: wire.status,
           error_code: response.error_code,
           message: response.error,
           response: response,
           operation: response.operation
         }}
      else
        {:ok, response}
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, kind}
      when kind in [:response, :deadline, :response_limit, :invalid_response, :invalid_envelope] ->
        {:error, %Error{kind: if(method in ["GET", "HEAD"], do: kind, else: :uncertain)}}

      {:error, kind} ->
        {:error, %Error{kind: kind}}
    end
  end

  @doc false
  def request_path(connection, path) when is_binary(path) do
    uri = URI.parse(path)

    if byte_size(path) <= 16_384 and
         (uri.path == "/1.0" or String.starts_with?(uri.path || "", "/1.0/")) and
         not String.starts_with?(path, "//") and
         is_nil(uri.host) and is_nil(uri.fragment) and
         not String.contains?(path, ["\r", "\n", <<0>>]) do
      query = URI.query_decoder(uri.query || "") |> Enum.to_list()

      project =
        if Enum.any?(query, fn {key, value} -> key == "all-projects" and value != "" end),
          do: nil,
          else: connection.project

      with {:ok, query} <- select(query, "project", project),
           {:ok, query} <- select(query, "target", connection.member) do
        query = URI.encode_query(query)
        {:ok, uri.path <> if(query == "", do: "", else: "?" <> query)}
      end
    else
      {:error, :invalid_path}
    end
  rescue
    _ -> {:error, :invalid_path}
  end

  def request_path(_, _), do: {:error, :invalid_path}
  defp select(query, _, nil), do: {:ok, query}

  defp select(query, key, value) do
    if Enum.any?(query, fn {existing, selected} -> existing == key and selected != value end),
      do: {:error, :selection_mismatch},
      else: {:ok, Enum.reject(query, fn {existing, _} -> existing == key end) ++ [{key, value}]}
  end

  defp request_body(connection, method, opts) do
    if method in ["GET", "HEAD", "PUT", "POST", "PATCH", "DELETE"] and
         Keyword.keys(opts) -- [:body, :etag] == [] do
      with {:ok, body} <- encode(Keyword.get(opts, :body)),
           true <- is_nil(body) or byte_size(body) <= connection.max_request_bytes do
        etag = Keyword.get(opts, :etag)
        headers = if is_nil(body), do: [], else: [{"content-type", "application/json"}]

        if is_nil(etag) or (is_binary(etag) and not String.contains?(etag, ["\r", "\n", <<0>>])) do
          {:ok, body, headers ++ if(is_nil(etag), do: [], else: [{"if-match", etag}])}
        else
          {:error, :invalid_etag}
        end
      else
        _ -> {:error, :invalid_body}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp encode(nil), do: {:ok, nil}
  defp encode(body), do: Jason.encode(body)
end

defimpl Inspect, for: Opsmaru.Incus do
  def inspect(_, _), do: "#Opsmaru.Incus<bound client redacted>"
end

defimpl Inspect, for: Opsmaru.Incus do
  def inspect(_, _), do: "#Opsmaru.Incus<host-bound client redacted>"
end
