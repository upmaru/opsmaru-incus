defmodule Opsmaru.TestSupport.TLSIdentity do
  @moduledoc "Disposable CA-signed identity for isolated TLS fixtures."

  def generate(root, name, hostname) do
    certfile = Path.join(root, name <> ".pem")
    keyfile = Path.join(root, name <> ".key")
    cafile = Path.join(root, name <> "-ca.pem")
    cakey = Path.join(root, name <> "-ca.key")
    csr = Path.join(root, name <> ".csr")
    extensions = Path.join(root, name <> ".extensions")

    run!([
      "req",
      "-sha256",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-pkeyopt",
      "ec_param_enc:named_curve",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=#{name}-fixture-ca",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-addext",
      "keyUsage=critical,keyCertSign,cRLSign",
      "-keyout",
      cakey,
      "-out",
      cafile
    ])

    run!([
      "req",
      "-sha256",
      "-new",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-pkeyopt",
      "ec_param_enc:named_curve",
      "-nodes",
      "-subj",
      "/CN=#{hostname}",
      "-keyout",
      keyfile,
      "-out",
      csr
    ])

    File.write!(
      extensions,
      "subjectAltName=DNS:#{hostname}\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth,clientAuth\n"
    )

    run!([
      "x509",
      "-sha256",
      "-req",
      "-in",
      csr,
      "-CA",
      cafile,
      "-CAkey",
      cakey,
      "-set_serial",
      "1",
      "-days",
      "1",
      "-extfile",
      extensions,
      "-out",
      certfile
    ])

    for path <- [certfile, keyfile, cafile, cakey, csr, extensions], do: File.chmod!(path, 0o600)
    [{:Certificate, der, _}] = :public_key.pem_decode(File.read!(certfile))
    %{certfile: certfile, keyfile: keyfile, cafile: cafile, der: der}
  end

  defp run!(args) do
    {output, status} = System.cmd("openssl", args, stderr_to_stdout: true)
    if status != 0, do: raise("fixture certificate generation failed: #{output}")
  end
end
