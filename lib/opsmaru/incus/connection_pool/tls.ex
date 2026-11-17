defmodule Opsmaru.Incus.ConnectionPool.TLS do
  @moduledoc false
  alias Opsmaru.Incus.Connection
  require Record

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  @max_pem_bytes 1_048_576
  @private_key_types [:RSAPrivateKey, :DSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo]
  @challenge "opsmaru_incus TLS key match"

  def snapshot(%Connection{tls: tls, address: uri} = connection) do
    certificate = read_pem!(tls[:certfile])
    private_key = read_pem!(tls[:keyfile])
    ca = if tls[:cacertfile], do: read_pem!(tls[:cacertfile])
    fingerprint = if tls[:fingerprint], do: Base.decode16!(tls[:fingerprint], case: :mixed)

    key =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {connection.owner, :https, uri.host, uri.port, connection.require_authenticated,
           certificate, private_key, ca, fingerprint},
          [:deterministic]
        )
      )

    {:ok, key, {certificate, private_key, ca}}
  rescue
    _ -> {:error, :connection}
  end

  def options(connection, {certificate, private_key, ca}) do
    [leaf | _] = chain = Connection.decode_certificates!(certificate)

    [{type, der, :not_encrypted} = entry] =
      Enum.filter(:public_key.pem_decode(private_key), &(elem(&1, 0) in @private_key_types))

    true = key_matches?(leaf, :public_key.pem_entry_decode(entry))
    cas = if ca, do: Connection.decode_certificates!(ca), else: []

    Connection.tls_options(connection, [cert: chain, key: {type, der}], cas)
  end

  defp key_matches?(leaf, private_key) do
    key_info = leaf |> :public_key.pkix_decode_cert(:otp) |> certificate(:tbsCertificate)

    public_key_info(algorithm: algorithm, subjectPublicKey: key) =
      tbs(key_info, :subjectPublicKeyInfo)

    {key, digest} = verification_key(algorithm, key)

    signature = :public_key.sign(@challenge, digest, private_key)
    :public_key.verify(@challenge, digest, signature, key)
  end

  defp verification_key(algorithm(algorithm: oid), key)
       when oid in [{1, 3, 101, 112}, {1, 3, 101, 113}],
       do: {{key, {:namedCurve, oid}}, :none}

  defp verification_key(algorithm(parameters: parameters), {:ECPoint, _} = key),
    do: {{key, parameters}, :sha256}

  defp verification_key(algorithm(parameters: {:params, parameters}), key) when is_integer(key),
    do: {{key, parameters}, :sha256}

  defp verification_key(_, key), do: {key, :sha256}

  defp read_pem!(path) do
    %{type: :regular, size: size} = File.stat!(path)
    true = size <= @max_pem_bytes

    bytes = File.open!(path, [:read, :binary], &IO.binread(&1, @max_pem_bytes + 1))
    true = is_binary(bytes) and byte_size(bytes) <= @max_pem_bytes
    bytes
  end
end
