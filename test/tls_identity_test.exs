defmodule Opsmaru.Incus.TLSIdentityTest do
  use ExUnit.Case, async: true
  alias Opsmaru.TestSupport.TLSIdentity
  @driver Path.expand("../../.integration/tls-identity-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./requestcontext"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "disposable CA and leaf use explicit SHA-256 signatures accepted by native verifiers" do
    root = Path.join(System.tmp_dir!(), "op-strong-tls-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    identity = TLSIdentity.generate(root, "strong", "localhost")
    verify_identity(identity)
  end

  test "ambient CA extensions cannot duplicate the disposable fixture configuration" do
    root = Path.join(System.tmp_dir!(), "op-ambient-tls-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    script = Path.expand("support/tls_defaults_trial.exs", __DIR__)

    {out, status} =
      System.cmd("mise", ["exec", "--", "mix", "run", "--no-start", script, root],
        env: [{"MIX_ENV", "library"}],
        stderr_to_stdout: true
      )

    assert status == 0, out

    verify_identity(%{
      cafile: Path.join(root, "ambient-ca.pem"),
      certfile: Path.join(root, "ambient.pem"),
      keyfile: Path.join(root, "ambient.key")
    })
  end

  defp verify_identity(identity) do
    for path <- [identity.cafile, identity.certfile] do
      [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(File.read!(path))
      {:Certificate, tbs, signature, _} = :public_key.der_decode(:Certificate, der)
      assert elem(signature, 1) == {1, 2, 840, 10_045, 4, 3, 2}
      extensions = elem(tbs, 10)
      oids = Enum.map(extensions, &elem(&1, 1))
      assert length(oids) == length(Enum.uniq(oids))
    end

    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])

    Port.command(
      port,
      Jason.encode!(%{
        Mode: "verify_fixture",
        CA: File.read!(identity.cafile),
        Cert: File.read!(identity.certfile),
        Key: File.read!(identity.keyfile)
      }) <> "\n"
    )

    result = collect(port, "")
    assert result["ok"], inspect(result)
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)

      {^port, {:exit_status, status}} ->
        flunk("native certificate verifier failed #{status}: #{data}")
    after
      5_000 ->
        Port.close(port)
        flunk("native certificate verifier deadline")
    end
  end
end
