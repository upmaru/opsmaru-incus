defmodule Opsmaru.Incus.TLSIdentityTest do
  use ExUnit.Case, async: true
  alias Opsmaru.TestSupport.TLSIdentity

  test "disposable CA and leaf use explicit SHA-256 signatures accepted by native verifiers" do
    root = Path.join(System.tmp_dir!(), "op-strong-tls-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    identity = TLSIdentity.generate(root, "strong", "localhost")

    for path <- [identity.cafile, identity.certfile] do
      [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(File.read!(path))
      {:Certificate, _, signature, _} = :public_key.der_decode(:Certificate, der)
      assert elem(signature, 1) == {1, 2, 840, 10_045, 4, 3, 2}
    end
  end
end
