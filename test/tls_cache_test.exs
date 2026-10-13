defmodule Opsmaru.Incus.TLSCacheTest do
  use ExUnit.Case, async: false

  test "deleted CA-file invalidation cannot crash an unrelated TLS manager" do
    root = Path.join(System.tmp_dir!(), "op-tls-cache-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    args = [
      "exec",
      "--",
      "mix",
      "run",
      "--no-start",
      "test/support/tls_cache_trial.exs",
      root
    ]

    {out, status} =
      System.cmd("mise", args, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "Deleted CA refresh preserves SSL manager"
  end
end
