defmodule Opsmaru.Incus.AcceptanceRunnerTest do
  use ExUnit.Case, async: false
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  @runner Path.expand("../scripts/accept-incus.exs", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "op-accept-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for scenario <- [:different_certificate, :existing_remote_project, :cloned_identity] do
    test "live runner #{scenario} cannot mutate the other backend", %{root: root} do
      run_scenario(root, unquote(scenario))
    end
  end

  defp run_scenario(root, scenario) do
    identity = TLSIdentity.generate(root, "remote", "localhost")

    local_identity =
      if scenario == :different_certificate,
        do: TLSIdentity.generate(root, "local", "localhost"),
        else: identity

    {:ok, marker} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(marker), do: Agent.stop(marker) end)
    local = fixture(root, :unix, local_identity, scenario, marker)
    remote = fixture(root, :https, identity, scenario, marker)
    config = Path.join(root, "config.json")

    File.write!(
      config,
      Jason.encode!(%{
        allow_namespaced_mutations: true,
        project: "opsmaru-acceptance-fixture",
        report: Path.join(root, "report.json"),
        socket: HTTPFixture.endpoint(local).socket,
        https: HTTPFixture.endpoint(remote).url,
        server_certificate: identity.certfile,
        client_certificate: identity.certfile,
        client_key: identity.keyfile,
        expected_version: "7.0.1",
        pool: "fixture-pool"
      })
    )

    {out, status} =
      System.cmd("mise", ["exec", "--", "mix", "run", "--no-start", @runner],
        cd: Path.expand("..", __DIR__),
        env: [{"MIX_ENV", "test"}, {"OPSMARU_ACCEPTANCE_CONFIG", config}],
        stderr_to_stdout: true
      )

    assert status != 0, out
    assert Enum.all?(HTTPFixture.requests(remote), &(&1.method == "GET"))
    mutations = Enum.reject(HTTPFixture.requests(local), &(&1.method == "GET"))

    if scenario == :cloned_identity do
      assert [%{method: "POST", target: "/1.0/projects"}] = mutations, out

      assert Enum.count(
               HTTPFixture.requests(remote),
               &String.starts_with?(&1.target, "/1.0/projects/")
             ) == 2

      assert Agent.get(marker, & &1) =~ "Opsmaru isolated direct-client acceptance "
    else
      assert mutations == []

      assert out =~
               if(scenario == :different_certificate,
                 do: "Acceptance backend identity mismatch",
                 else: "Acceptance project must be absent on both transports"
               )

      refute File.exists?(Path.join(root, "report.json"))
    end

    refute out =~ "PRIVATE KEY"
  end

  defp fixture(root, transport, identity, scenario, marker) do
    opts =
      if transport == :unix,
        do: [transport: :gen_tcp, path: Path.join(root, "local.sock")],
        else: [transport: :ssl, certfile: identity.certfile, keyfile: identity.keyfile]

    start_supervised!(
      {HTTPFixture,
       opts ++
         [
           handler: fn request ->
             path = URI.parse(request.target).path

             cond do
               path == "/1.0" ->
                 success(%{
                   api_version: "1.0",
                   api_extensions: ["projects", "storage"],
                   auth: "trusted",
                   environment: %{
                     server_version: "7.0.1",
                     server_name: "same-name",
                     certificate: File.read!(identity.certfile)
                   }
                 })

               request.method == "GET" and String.starts_with?(path, "/1.0/projects/") ->
                 project_response(transport, scenario, marker)

               request.method == "POST" and path == "/1.0/projects" ->
                 Agent.update(marker, fn _ -> Jason.decode!(request.body)["description"] end)
                 success(nil)

               String.starts_with?(path, "/1.0/storage-pools/") ->
                 success(%{name: "fixture-pool", status: "Created", driver: "dir"})

               true ->
                 missing()
             end
           end
         ]},
      id: make_ref()
    )
  end

  defp project_response(transport, scenario, marker) do
    description = Agent.get(marker, & &1)

    cond do
      transport == :https and scenario == :existing_remote_project ->
        success(%{name: "opsmaru-acceptance-fixture", description: "other owner's project"})

      transport == :unix and is_binary(description) ->
        success(%{name: "opsmaru-acceptance-fixture", description: description})

      true ->
        missing()
    end
  end

  defp success(metadata),
    do: %{status: 200, body: %{type: "sync", status_code: 200, metadata: metadata}}

  defp missing, do: %{status: 404, body: %{type: "error", error_code: 404, error: "missing"}}
end
