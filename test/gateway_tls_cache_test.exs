defmodule Opsmaru.Incus.GatewayTLSCacheTest do
  use ExUnit.Case, async: true

  test "gateway TLS fixtures keep trusted bytes out of OTP's global file refresh cache" do
    root = Path.join(System.tmp_dir!(), "gateway-ca-cache-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    {output, status} =
      System.cmd(
        "mise",
        [
          "exec",
          "--",
          "mix",
          "run",
          "--no-start",
          "--no-compile",
          "--no-deps-check",
          "test/support/gateway_tls_cache_trial.exs",
          root
        ],
        env: [{"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Gateway TLS fixtures retain their original SSL manager"
  end
end
