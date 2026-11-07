Code.require_file(Path.expand("../scripts/gateway-acceptance-host.exs", __DIR__))

defmodule Opsmaru.Incus.GatewayAcceptanceHostTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.Incus.Gateway.{Policy, Request}
  alias Opsmaru.TestSupport.HTTPFixture
  alias OpsmaruGatewayAcceptance, as: Runner
  alias OpsmaruGatewayAcceptance.Host

  test "loading modules and missing opt-in never start acceptance or contact backend", context do
    assert_raise ArgumentError, "explicit mutation opt-in required", fn ->
      Runner.run(%{"allow_namespaced_mutations" => false}, fn _ -> flunk("scenario ran") end)
    end

    assert Admission.count(context.admission) == 0
    assert length(Runner.required_cases()) == 35
  end

  test "only six explicitly accepted native snapshot-move limitations satisfy completeness" do
    passed = Map.new(Runner.required_cases(), &{&1, "passed"})

    accepted =
      Enum.reduce(
        Runner.accepted_native_limitations(),
        passed,
        &Map.put(&2, &1, "native_limitation")
      )

    assert Runner.evidence_complete?(accepted)
    refute Runner.evidence_complete?(Map.put(accepted, "nbd", "native_limitation"))
    refute Runner.evidence_complete?(Map.put(accepted, "console", "unrun"))
  end

  test "only verified owned migration operations admit anonymous server peers", context do
    {host, caller} = host(context)
    request = request(nil, "project", "pending")
    assert {:error, :forbidden} = Host.admit_operation_secret(request, host)
    operation = operation("pending", "Creating instance", "websocket")
    Host.register(host, [operation])
    assert {:ok, grant} = Host.admit_operation_secret(request, host)
    assert Host.valid?(request, grant, host)
    assert {:ok, ^grant} = Host.admit_operation_secret(%{request | project: nil}, host)
    assert {:error, :forbidden} = Host.admit_operation_secret(%{request | project: "other"}, host)

    assert {:error, :forbidden} =
             Host.admit_operation_secret(%{request | operation: "other"}, host)

    assert {:error, :forbidden} =
             Host.admit_operation_secret(
               %{request | peer: %{request.peer | address: {192, 0, 2, 9}}},
               host
             )

    assert {:ok, {:caller, ^caller}} =
             Host.authorize(%{request | peer: %{request.peer | certificate: <<1, 2, 3>>}}, host)

    for operation <- [
          operation("exec", "Executing command", "websocket"),
          operation("task", "Creating instance", "task"),
          put_in(
            operation("foreign", "Migrating instance", "websocket"),
            ["resources", "instances"],
            ["/1.0/instances/not-our-run"]
          )
        ] do
      Host.register(host, [operation])

      assert {:error, :forbidden} =
               Host.admit_operation_secret(%{request | operation: operation["id"]}, host)
    end

    Agent.update(host.state, &%{&1 | ready: false, operations: %{}})
    refute Host.valid?(request, grant, host)
  end

  test "project query cannot authorize global writes or another pool before backend access",
       context do
    {host, _} = host(context)
    {backend, connection} = backend(context, reply(200, %{}))

    gateway =
      Gateway.new!(
        connection: connection,
        host: Host,
        host_config: host,
        admission: context.admission
      )

    for {method, path} <- [
          {"POST", "/1.0/projects"},
          {"DELETE", "/1.0/projects/production"},
          {"PUT", "/1.0"},
          {"PUT", "/1.0/cluster"},
          {"POST", "/1.0/storage-pools"},
          {"DELETE", "/1.0/storage-pools/default"},
          {"PUT", "/1.0/networks/production"},
          {"DELETE", "/1.0/storage-pools/other/volumes/custom/gw-test-volume"}
        ] do
      request = %Request{
        protocol: :http,
        method: method,
        path: path,
        query: "project=project",
        project: "project",
        peer: %{address: {127, 0, 0, 1}, certificate: <<1, 2, 3>>}
      }

      assert {:error, %{status: 403}} = Policy.admit(gateway, request)
    end

    assert Host.requests(host) == []
    assert StreamBackend.accepted(backend) == 0
  end

  test "certificate enrollment is ephemeral and bound to configured TLS peer", context do
    {host, caller} = host(context)
    Agent.update(host.state, &%{&1 | trust: %{}})
    request = request(<<1, 2, 3>>, nil, nil)
    input = %{body: %{"trust_token" => "single-use"}}
    refute inspect(:sys.get_status(host.state)) =~ "single-use"

    assert {:error, 403} =
             Host.certificates(
               :create,
               %{request | peer: %{request.peer | certificate: <<9>>}},
               nil,
               input,
               host
             )

    assert {:ok, %{}, _} = Host.certificates(:create, request, nil, input, host)
    assert {:ok, {:caller, ^caller}} = Host.authorize(%{request | path: "/1.0"}, host)
    assert {:error, 403} = Host.certificates(:create, request, nil, input, host)
    assert {:error, 501} = Host.certificates(:delete, request, {:caller, caller}, %{}, host)
  end

  test "full fixture runtime verifies fresh projects and marker, mounts hosts, retains partial evidence",
       context do
    {config, backend_state} = config(context)

    result =
      Runner.run(config, fn runtime ->
        assert runtime.resource_prefix =~ "gw-"
        assert File.dir?(runtime.incus_conf)

        for side <- ~w(source target) do
          await_ready(runtime.sides[side].host)
          assert runtime.sides[side].client.connection.project == config[side]["project"]
          port = URI.parse(runtime.sides[side].origin).port
          credentials = config[side]["gateway"]

          tls = [
            verify: :verify_peer,
            cacertfile: String.to_charlist(credentials["server_ca"]),
            certfile: String.to_charlist(credentials["client_certificate"]),
            keyfile: String.to_charlist(credentials["client_key"]),
            server_name_indication: ~c"localhost"
          ]

          response =
            RawHTTP.request(port, "GET", "/1.0?project=" <> config[side]["project"], [], "", tls)

          assert response.status == 200

          assert native(response.body)["metadata"]["environment"]["certificate"] ==
                   File.read!(credentials["server_certificate"])

          denied =
            RawHTTP.request(
              port,
              "POST",
              "/1.0/projects?project=" <> config[side]["project"],
              [],
              "{}",
              tls
            )

          assert denied.status == 403
          assert [%{method: "GET", path: "/1.0"}] = Host.requests(runtime.sides[side].host)
        end

        Runner.record_case(runtime, "discovery", "passed")

        assert_raise ArgumentError, "partial acceptance cannot be marked cleaned", fn ->
          Runner.mark_cleaned(runtime)
        end

        Runner.record_detail(runtime, "interruption-accepted", %{
          "operation_id" => "known-native-id",
          "bytes" => 1
        })

        assert_raise ArgumentError, fn ->
          Runner.record_detail(runtime, "bad-output", %{"raw_stdout" => "private"})
        end
      end)

    assert result["phase"] == "partial-resources-retained"
    assert byte_size(result["run_marker"]) == 32
    assert byte_size(result["config_fingerprint"]) == 64
    assert byte_size(result["host_source_sha256"]) == 64
    assert result["backend_identities"]["source"]["server_name"] == "fixture"
    assert result["cases"]["discovery"] == "passed"
    assert result["cases"]["exec"] == "unrun"
    assert result["installed_host"] == "unrun"
    assert result["macus_hardware"] == "unrun"
    assert length(Agent.get(backend_state, & &1.posts)) == 2
    assert map_size(Agent.get(backend_state, & &1.projects)) == 2
    assert Jason.decode!(File.read!(config["report"])) == result
    assert Bitwise.band(File.stat!(config["report"]).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(config["state_directory"]).mode, 0o777) == 0o700
    refute File.read!(config["report"]) =~ "BEGIN PRIVATE KEY"
  end

  test "existing namespace prevents every mutation and failure journal preserves resources",
       context do
    {config, backend_state} = config(context)

    Agent.update(
      backend_state,
      &put_in(&1, [:projects, config["target"]["project"]], %{"description" => "existing"})
    )

    assert_raise MatchError, fn -> Runner.run(config, fn _ -> flunk("scenario ran") end) end
    assert Agent.get(backend_state, & &1.posts) == []
    assert Jason.decode!(File.read!(config["report"]))["phase"] == "failed-resources-retained"
  end

  test "scenario failure stops local listeners but retains exact project intent journal",
       context do
    {config, backend_state} = config(context)

    assert_raise RuntimeError, "scenario failed", fn ->
      Runner.run(config, fn _ -> raise "scenario failed" end)
    end

    assert map_size(Agent.get(backend_state, & &1.projects)) == 2
    report = Jason.decode!(File.read!(config["report"]))
    assert report["phase"] == "failed-resources-retained"
    assert Enum.all?(report["cases"], fn {_, outcome} -> outcome == "unrun" end)

    for side <- ~w(source target) do
      port = URI.parse(config[side]["gateway"]["https"]).port

      assert {:error, :econnrefused} =
               :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 200)
    end
  end

  test "successful cleanup phase requires complete ledger and both project absences", context do
    {config, backend_state} = config(context)

    report =
      Runner.run(config, fn runtime ->
        for name <- Runner.required_cases(), do: Runner.record_case(runtime, name, "passed")
        assert_raise MatchError, fn -> Runner.mark_cleaned(runtime) end
        Agent.update(backend_state, &%{&1 | projects: %{}})
        assert :ok = Runner.mark_cleaned(runtime)
      end)

    assert report["phase"] == "passed-and-cleaned"
    assert report["cleanup"] == "verified-projects-absent"
  end

  test "owner loss closes local hosts and retains backend project evidence", context do
    {config, backend_state} = config(context)
    observer = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        Runner.run(config, fn _ ->
          send(observer, :hosts_running)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :hosts_running, 5_000
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    for side <- ~w(source target) do
      await_closed(URI.parse(config[side]["gateway"]["https"]).port)
    end

    assert map_size(Agent.get(backend_state, & &1.projects)) == 2
    report = Jason.decode!(File.read!(config["report"]))
    assert report["phase"] == "host-mounted-protocols-unrun"
    assert report["run_marker"] != nil
  end

  defp await_closed(port, remaining \\ 100)

  defp await_closed(port, 0),
    do:
      assert(
        {:error, :econnrefused} =
          :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100)
      )

  defp await_closed(port, remaining) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:error, :econnrefused} ->
        :ok

      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(10)
        await_closed(port, remaining - 1)
    end
  end

  defp host(context) do
    caller = Host.fingerprint(<<1, 2, 3>>)

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             owner: self(),
             ready: true,
             last_poll: System.monotonic_time(:millisecond),
             trust: %{caller => true},
             client_der: <<1, 2, 3>>,
             token_digest: :crypto.hash(:sha256, "single-use"),
             verified_peers: [{127, 0, 0, 1}],
             operations: %{}
           }
         end},
        id: make_ref()
      )

    {%{
       state: state,
       project: "project",
       allowed_peers: [{127, 0, 0, 1}],
       resource_prefix: "gw-test-",
       pool: "default",
       image: String.duplicate("a", 64),
       identity: %{},
       connection: context[:connection]
     }, caller}
  end

  defp request(certificate, project, operation) do
    %Request{
      protocol: :websocket,
      method: "GET",
      path: "/1.0/operations/pending/websocket",
      query: "secret=private",
      operation: operation,
      project: project,
      peer: %{address: {127, 0, 0, 1}, certificate: certificate}
    }
  end

  defp operation(id, description, class),
    do: %{
      "id" => id,
      "class" => class,
      "description" => description,
      "status_code" => 103,
      "resources" => %{"instances" => ["/1.0/instances/gw-test-instance"]},
      "metadata" => %{"control" => "private-control", "fs" => "private-fs"}
    }

  defp await_ready(host, remaining \\ 100)
  defp await_ready(host, 0), do: assert(Host.ready?(host))

  defp await_ready(host, remaining) do
    if Host.ready?(host),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_ready(host, remaining - 1)
        )
  end

  defp config(context) do
    state = start_supervised!({Agent, fn -> %{projects: %{}, posts: []} end}, id: make_ref())
    identity = TLSIdentity.generate(context.root, "backend", "backend.example.com")
    certificate = File.read!(identity.certfile)

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(context.root, "live-fixture.sock"),
         handler: &respond(&1, state, certificate)},
        id: make_ref()
      )

    client = TLSIdentity.generate(context.root, "live-client", "caller")

    sides =
      for side <- ~w(source target), into: %{} do
        server = TLSIdentity.generate(context.root, "live-front-" <> side, "localhost")
        {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
        {:ok, {_, port}} = :inet.sockname(socket)
        :gen_tcp.close(socket)

        {side,
         %{
           "project" => "opsmaru-acceptance-gateway-test-" <> side,
           "image" => String.duplicate("a", 64),
           "pool" => "default",
           "backend" => %{"socket" => HTTPFixture.endpoint(fixture).socket},
           "expected_identity" => %{
             "server_name" => "fixture",
             "certificate_sha256" => Runner.certificate_pin(certificate)
           },
           "gateway" => %{
             "https" => "https://gateway.example.com:#{port}",
             "bind_ip" => "127.0.0.1",
             "allowed_operation_peers" => ["127.0.0.1"],
             "server_certificate" => server.certfile,
             "server_key" => server.keyfile,
             "client_certificate" => client.certfile,
             "client_key" => client.keyfile,
             "client_ca" => client.cafile,
             "server_ca" => server.cafile
           }
         }}
      end

    {Map.merge(sides, %{
       "allow_namespaced_mutations" => true,
       "expected_version" => "7.0.1",
       "report" => Path.join(context.root, "report.json"),
       "state_directory" => Path.join(context.root, "live-state")
     }), state}
  end

  defp respond(request, state, certificate) do
    path = URI.parse(request.target).path

    cond do
      path == "/1.0" ->
        sync(%{
          api_version: "1.0",
          api_extensions: ["instances", "projects", "storage"],
          environment: %{
            server_name: "fixture",
            server_version: "7.0.1",
            certificate: certificate
          }
        })

      path == "/1.0/projects" and request.method == "POST" ->
        body = Jason.decode!(request.body)

        Agent.update(
          state,
          &%{&1 | projects: Map.put(&1.projects, body["name"], body), posts: [body | &1.posts]}
        )

        sync(%{})

      String.starts_with?(path, "/1.0/projects/") ->
        name = String.replace_prefix(path, "/1.0/projects/", "")

        case Agent.get(state, &Map.get(&1.projects, name)) do
          nil -> %{status: 404, body: %{type: "error", error: "not found", error_code: 404}}
          body -> sync(body)
        end

      String.starts_with?(path, "/1.0/images/") ->
        sync(%{fingerprint: String.duplicate("a", 64), type: "container"})

      String.starts_with?(path, "/1.0/storage-pools/") ->
        sync(%{name: "default", status: "Created"})

      path == "/1.0/operations" ->
        sync(%{"running" => []})
    end
  end

  defp sync(data),
    do: %{status: 200, body: %{type: "sync", status: "Success", status_code: 200, metadata: data}}
end
