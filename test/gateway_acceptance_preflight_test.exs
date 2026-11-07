defmodule Opsmaru.Incus.GatewayAcceptancePreflightTest do
  use ExUnit.Case, async: true
  alias Opsmaru.TestSupport.HTTPFixture
  @script Path.expand("../scripts/gateway-acceptance-preflight.py", __DIR__)

  test "entrypoint requires explicit opt-in, preserves reports, and never contacts configured backends" do
    root = Path.join(System.tmp_dir!(), "gateway-preflight-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "configured-backend.sock"),
         handler: fn _ -> %{status: 500, body: "unexpected"} end}
      )

    reference = Path.join(root, "private-reference")
    File.write!(reference, "PRIVATE SENTINEL MUST NOT APPEAR IN OUTPUT")
    origin = "https://configured-gateway.invalid:8443"

    tls = %{
      https: origin,
      server_certificate: reference,
      client_certificate: reference,
      client_key: reference
    }

    config = %{
      allow_namespaced_mutations: true,
      expected_version: "7.0.1",
      project: "opsmaru-acceptance-gateway-fixture",
      report: Path.join(root, "report.json"),
      source: %{
        gateway: tls,
        backend: %{socket: HTTPFixture.endpoint(fixture).socket},
        image: "fixture",
        pool: "fixture"
      },
      target: %{
        gateway: tls,
        backend: %{socket: Path.join(root, "target.sock")},
        image: "fixture",
        pool: "fixture"
      }
    }

    path = Path.join(root, "config.json")

    {output, status} = run("")
    assert status == 2
    refute output =~ reference
    refute File.exists?(config.report)

    File.write!(path, Jason.encode!(%{config | allow_namespaced_mutations: false}))
    assert {_, 2} = run(path)
    refute File.exists?(config.report)

    File.write!(
      path,
      String.replace(
        Jason.encode!(config),
        "\"allow_namespaced_mutations\":true",
        "\"allow_namespaced_mutations\":false,\"allow_namespaced_mutations\":true"
      )
    )

    assert {_, 2} = run(path)
    refute File.exists?(config.report)

    File.write!(path, Jason.encode!(config))
    assert {output, 0} = run(path)
    report = File.read!(config.report)
    assert Jason.decode!(report)["phase"] == "unrun"
    assert Jason.decode!(report)["protocol_acceptance"] == "unrun"
    assert Jason.decode!(report)["backend_access"] == "unrun"
    refute output =~ origin
    refute output =~ reference
    refute output =~ "PRIVATE SENTINEL"
    assert {_, 2} = run(path)
    assert File.read!(config.report) == report

    isolated_projects = %{
      config
      | report: Path.join(root, "project-report.json"),
        target: Map.merge(config.source, %{project: "opsmaru-acceptance-gateway-other"})
    }

    File.write!(path, Jason.encode!(isolated_projects))
    assert {_, 0} = run(path)

    assert Jason.decode!(File.read!(isolated_projects.report))["projects"]["target"] ==
             "opsmaru-acceptance-gateway-other"

    assert HTTPFixture.requests(fixture) == []
  end

  defp run(path),
    do:
      System.cmd("python3", [@script],
        env: [{"OPSMARU_GATEWAY_ACCEPTANCE_CONFIG", path}],
        stderr_to_stdout: true
      )
end
