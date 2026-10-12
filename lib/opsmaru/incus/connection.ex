defmodule Opsmaru.Incus.Connection do
  alias Opsmaru.Incus.ServerTrust

  @moduledoc """
  Explicit immutable host-selected backend. Construction performs no I/O.

  `unix!/2` requires an absolute owner-private socket. `https!/2` requires an
  HTTPS origin, CA certificate file, client certificate and private-key files.
  TLS verifies both trust and hostname. Secret files are opened only for an
  authorized call; paths are never included in diagnostics or Inspect output.
  Connections are privileged host configuration, not agent-selected URLs.
  """
  @enforce_keys [:owner, :transport, :address]
  defstruct [
    :owner,
    :transport,
    :address,
    :tls,
    :project,
    :member,
    require_authenticated: false,
    timeout: 5_000,
    max_response_bytes: 8_388_608,
    max_request_bytes: 8_388_608,
    stream_timeout: 60_000,
    max_stream_bytes: 1_073_741_824,
    max_chunk_bytes: 65_536,
    queue_limit: 64
  ]

  @type t :: %__MODULE__{}

  def unix!(path, opts) do
    unless is_binary(path) and Path.type(path) == :absolute and not String.contains?(path, <<0>>),
      do: raise(ArgumentError, "Unix socket must be an absolute path")

    new!(opts, :unix, path, nil)
  end

  def https!(url, opts) do
    uri = URI.parse(url)

    unless valid_origin?(uri),
      do: raise(ArgumentError, "HTTPS backend must be an origin without userinfo, path or query")

    tls = Keyword.fetch!(opts, :tls)

    unless valid_tls_references?(tls),
      do:
        raise(
          ArgumentError,
          "TLS requires CA, client certificate and private-key file references"
        )

    validate_tls_files!(tls)

    if tls[:fingerprint] && not Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, tls[:fingerprint]),
      do: raise(ArgumentError, "server fingerprint must be a SHA-256 hexadecimal digest")

    new!(Keyword.delete(opts, :tls), :https, %{uri | path: nil}, tls)
  end

  defp valid_origin?(uri),
    do:
      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and uri.port in 1..65_535 and
        uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and is_nil(uri.query) and
        is_nil(uri.fragment)

  defp valid_tls_references?(tls),
    do:
      (is_list(tls) and
         Keyword.keys(tls) -- [:cacertfile, :certfile, :keyfile, :fingerprint] == [] and
         tls[:certfile]) && tls[:keyfile] && (tls[:cacertfile] || tls[:fingerprint])

  defp validate_tls_files!(tls) do
    for {key, path} <- tls, key != :fingerprint do
      unless is_binary(path) and Path.type(path) == :absolute and
               not String.contains?(path, <<0>>),
             do: raise(ArgumentError, "TLS file references must be absolute paths")
    end
  end

  @doc "Select a native project without changing any other connection."
  def project(connection, project), do: %{connection | project: selection!(project)}
  @doc "Select a native cluster member (`target`)."
  def member(connection, member), do: %{connection | member: selection!(member)}

  @doc false
  def tls_options(%__MODULE__{tls: tls, address: uri}) do
    options = [
      verify: :verify_peer,
      versions: [:"tlsv1.3", :"tlsv1.2"],
      certfile: String.to_charlist(tls[:certfile]),
      keyfile: String.to_charlist(tls[:keyfile])
    ]

    options =
      if tls[:cacertfile],
        do: Keyword.put(options, :cacerts, ca_certificates(tls[:cacertfile])),
        else: Keyword.put(options, :cacerts, [])

    if tls[:fingerprint] do
      Keyword.put(
        options,
        :verify_fun,
        {&ServerTrust.verify/3,
         %{
           digest: Base.decode16!(tls[:fingerprint], case: :mixed),
           hostname: uri.host,
           ca: not is_nil(tls[:cacertfile])
         }}
      )
    else
      options
    end
  end

  @doc false
  def ca_certificates(path) do
    # Resolve trusted bytes per authorized connection, rather than registering
    # a host file in OTP's shared periodic trust-file refresh cache.
    %{type: :regular, size: size} = File.stat!(path)
    if size > 1_048_576, do: raise(ArgumentError, "CA bundle exceeds its byte limit")
    bytes = File.read!(path)
    if byte_size(bytes) > 1_048_576, do: raise(ArgumentError, "CA bundle exceeds its byte limit")

    certificates =
      for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(bytes), do: der

    unless length(certificates) in 1..256, do: raise(ArgumentError, "Invalid CA bundle")
    certificates
  end

  defp new!(opts, transport, address, tls) do
    connection =
      struct!(__MODULE__, Keyword.merge(opts, transport: transport, address: address, tls: tls))

    if is_nil(connection.owner), do: raise(ArgumentError, "connection owner is required")

    unless is_boolean(connection.require_authenticated),
      do: raise(ArgumentError, "require_authenticated must be a boolean")

    selection!(connection.project)
    selection!(connection.member)

    for key <- [:timeout, :stream_timeout] do
      unless Map.fetch!(connection, key) in 1..3_600_000,
        do: raise(ArgumentError, "deadlines must be positive and at most one hour")
    end

    for key <- [
          :max_response_bytes,
          :max_request_bytes,
          :max_stream_bytes,
          :max_chunk_bytes,
          :queue_limit
        ] do
      value = Map.fetch!(connection, key)

      unless is_integer(value) and value > 0 and value <= 1_073_741_824,
        do: raise(ArgumentError, "client budgets must be bounded positive integers")
    end

    unless connection.queue_limit <= 4096 and connection.max_chunk_bytes <= 1_048_576,
      do: raise(ArgumentError, "queue/chunk budgets exceed supported bounds")

    connection
  end

  defp selection!(nil), do: nil
  defp selection!(value) when is_binary(value) and byte_size(value) in 1..1024, do: value

  defp selection!(_),
    do: raise(ArgumentError, "selection must be nil or a nonempty bounded string")
end

defimpl Inspect, for: Opsmaru.Incus.Connection do
  def inspect(connection, _),
    do: "#Opsmaru.Incus.Connection<#{connection.transport} credentials redacted>"
end
