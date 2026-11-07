Code.require_file(Path.expand("../scripts/gateway-acceptance-host.exs", __DIR__))

defmodule Opsmaru.Incus.GatewayAcceptanceHostTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Context, Error, RequestContext}
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

  test "live poll freshness and operation TTL cover both request deadlines with bounded slack",
       context do
    connection = Connection.unix!(Path.join(context.root, "never-opened.sock"), owner: :fixture)
    assert connection.timeout == 5_000
    budgets = Runner.poll_budgets(connection)
    assert budgets == %{freshness_ms: 12_000, operation_ttl_ms: 12_000, poll_interval_ms: 100}
    assert Runner.poll_budgets(%{connection | timeout: 50}).freshness_ms == 2_100
    {host, _} = host(context)
    live = Map.merge(host, budgets)
    now = System.monotonic_time(:millisecond)
    Host.register(live, [operation("pending", "Transferring snapshot", "websocket")], now - 7_000)
    assert Host.ready?(live)
    assert Agent.get(host.state, & &1.operations["pending"].expires) == now + 5_000
    assert {:ok, grant} = Host.admit_operation_secret(request(nil, "project", "pending"), live)
    assert Host.valid?(request(nil, "project", "pending"), grant, live)
    refute File.exists?(connection.address)

    # Hand-built fixtures retain their prior defaults; live bounds do not weaken them.
    Host.register(host, [operation("pending", "Transferring snapshot", "websocket")], now - 3_000)
    refute Host.ready?(host)
    assert Agent.get(host.state, & &1.operations["pending"].expires) == now + 2_000
    Agent.update(host.state, &%{&1 | last_poll: now - budgets.freshness_ms - 1})
    refute Host.ready?(live)

    Host.register(
      live,
      [operation("pending", "Transferring snapshot", "websocket")],
      now - budgets.operation_ttl_ms - 1
    )

    assert Agent.get(host.state, & &1.operations["pending"].expires) == now - 1
    refute Host.valid?(request(nil, "project", "pending"), grant, live)
  end

  test "poll RPC failures clear authority and record only bounded safe stage diagnostics",
       context do
    {runtime, host, state, fixture} = poll_fixture(context)
    Host.register(host, [operation("pending", "Creating instance", "websocket")])
    Agent.update(state, &Map.put(&1, :mode, :operations_error))
    assert :continue = Runner.poll_once(runtime, "source", host)
    refute Host.ready?(host)
    assert Agent.get(host.state, & &1.operations) == %{}
    [%{"evidence" => failure}] = Agent.get(runtime.journal, & &1["details"])
    assert failure["proof"]["stage"] == "operations"
    assert failure["proof"]["retained_authority"] == false
    assert failure["error_kind"] == "native"
    assert failure["http_status"] == 503
    assert is_integer(failure["elapsed_ms"]) and failure["elapsed_ms"] >= 0
    refute File.read!(runtime.config["report"]) =~ "private-"
    refute File.read!(runtime.config["report"]) =~ "secret="

    for _ <- 1..18, do: assert(:continue == Runner.poll_once(runtime, "source", host))
    assert length(Agent.get(runtime.journal, & &1["details"])) == 1
    Agent.update(state, &Map.put(&1, :mode, :ok))
    assert :continue = Runner.poll_once(runtime, "source", host)
    assert Host.ready?(host)
    before_requests = length(HTTPFixture.requests(fixture))
    assert Host.ready?(host)

    refute Host.valid?(
             request(nil, "project", "pending"),
             {:migration, "pending", "project"},
             host
           )

    assert length(HTTPFixture.requests(fixture)) == before_requests
    assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))
  end

  test "project RPC, marker and owner failure stop polling without retaining operation authority",
       context do
    {runtime, host, state, fixture} = poll_fixture(context)

    for {mode, kind} <- [project_error: "native", marker_changed: "project_marker_mismatch"] do
      Host.register(host, [operation("pending", "Creating instance", "websocket")])
      Agent.update(state, &Map.put(&1, :mode, mode))
      before_requests = length(HTTPFixture.requests(fixture))
      assert :stop = Runner.poll_once(runtime, "source", host)
      assert length(HTTPFixture.requests(fixture)) == before_requests + 1
      assert Agent.get(host.state, & &1.operations) == %{}
      refute Host.ready?(host)
      failure = Agent.get(runtime.journal, &List.last(&1["details"])["evidence"])
      assert failure["proof"]["stage"] == "project"
      assert failure["error_kind"] == kind
    end

    {owner, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    Agent.update(host.state, &%{&1 | owner: owner})
    before_requests = length(HTTPFixture.requests(fixture))
    assert :stop = Runner.poll_once(runtime, "source", host)
    assert length(HTTPFixture.requests(fixture)) == before_requests
    failure = Agent.get(runtime.journal, &List.last(&1["details"])["evidence"])
    assert failure["proof"]["stage"] == "owner"
    assert failure["error_kind"] == "owner_lost"
    refute Host.ready?(host)
  end

  test "malformed operation metadata is identified separately from transport deadlines",
       context do
    {runtime, host, state, _} = poll_fixture(context)
    Host.register(host, [operation("pending", "Creating instance", "websocket")])
    Agent.update(state, &Map.put(&1, :mode, :operations_invalid))
    assert :continue = Runner.poll_once(runtime, "source", host)
    refute Host.ready?(host)
    assert Agent.get(host.state, & &1.operations) == %{}
    [%{"evidence" => failure}] = Agent.get(runtime.journal, & &1["details"])
    assert failure["error_kind"] == "invalid_model"
    assert failure["proof"]["stage"] == "operations"
    refute File.read!(runtime.config["report"]) =~ "private-malformed"
  end

  test "repeated early closes preserve only the exact original cache until its original expiry",
       context do
    {runtime, host, state, fixture} = poll_fixture(context)
    host = Map.merge(host, %{freshness_ms: 2_000, operation_ttl_ms: 2_000})
    Host.register(host, [operation("pending", "Creating instance", "websocket")])
    original = Agent.get(host.state, &Map.take(&1, [:last_poll, :operations]))
    assert {:ok, grant} = Host.admit_operation_secret(request(nil, "project", "pending"), host)
    Agent.update(state, &Map.put(&1, :mode, :project_closed))

    for _ <- 1..18 do
      assert :continue = Runner.poll_once(runtime, "source", host)
      assert Agent.get(host.state, &Map.take(&1, [:last_poll, :operations])) == original
      assert Host.ready?(host)
      assert Host.valid?(request(nil, "project", "pending"), grant, host)
    end

    assert {:error, :forbidden} =
             Host.admit_operation_secret(request(nil, "project", "unknown"), host)

    assert length(Agent.get(runtime.journal, & &1["details"])) == 15
    caller = Host.fingerprint(<<1, 2, 3>>)

    new_request = %{
      request(<<1, 2, 3>>, "project", nil)
      | protocol: :http,
        path: "/1.0/instances/gw-test-instance",
        query: "project=project"
    }

    before_requests = length(HTTPFixture.requests(fixture))
    assert {:ok, {:caller, ^caller}} = Host.authorize(new_request, host)
    assert length(HTTPFixture.requests(fixture)) == before_requests
    Agent.update(host.state, &%{&1 | trust: %{}})
    refute Host.valid?(request(<<1, 2, 3>>, "project", "pending"), {:caller, caller}, host)
    assert Agent.get(host.state, &Map.take(&1, [:last_poll, :operations])) == original

    Process.sleep(
      max(0, original.last_poll + host.freshness_ms - System.monotonic_time(:millisecond)) + 5
    )

    refute Host.ready?(host)
    refute Host.valid?(request(nil, "project", "pending"), grant, host)
    assert :stop = Runner.poll_once(runtime, "source", host)
    assert Agent.get(host.state, & &1.last_poll) == original.last_poll
    assert Agent.get(host.state, & &1.operations) == %{}
    details = Agent.get(runtime.journal, & &1["details"])
    assert length(details) == 16
    assert List.last(details)["evidence"]["error_kind"] == "cache_expired"
    assert List.last(details)["evidence"]["proof"]["remaining_cache_ms"] == 0
    assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))
  end

  test "connection failure retains a verified cache but an initial early close stays unready",
       context do
    {runtime, host, state, _} = poll_fixture(context)
    Agent.update(host.state, &%{&1 | ready: false, last_poll: 0})
    Agent.update(state, &Map.put(&1, :mode, :project_closed))
    assert :stop = Runner.poll_once(runtime, "source", host)
    refute Host.ready?(host)
    assert Agent.get(host.state, & &1.last_poll) == 0
    assert Agent.get(host.state, & &1.operations) == %{}
    failure = Agent.get(runtime.journal, &List.last(&1["details"])["evidence"])
    assert failure["proof"]["remaining_cache_ms"] == 0
    assert failure["proof"]["retained_authority"] == false

    Host.register(host, [operation("pending", "Creating instance", "websocket")])
    original = Agent.get(host.state, &Map.take(&1, [:last_poll, :operations]))
    client = runtime.clients["source"]

    client = %{
      client
      | connection: %{client.connection | address: client.connection.address <> ".absent"}
    }

    runtime = %{runtime | clients: %{"source" => client}}
    assert :continue = Runner.poll_once(runtime, "source", host)
    assert Agent.get(host.state, &Map.take(&1, [:last_poll, :operations])) == original
    assert Host.ready?(host)
  end

  test "hard native, marker and schema failures revoke a previously retained cache", context do
    for {mode, kind, action} <- [
          {:project_error, "native", :stop},
          {:project_truncated403, "response", :stop},
          {:project_truncated404, "response", :stop},
          {:marker_changed, "project_marker_mismatch", :stop},
          {:operations_invalid, "invalid_model", :continue}
        ] do
      {runtime, host, state, _} = poll_fixture(context)
      Host.register(host, [operation("pending", "Creating instance", "websocket")])
      original = Agent.get(host.state, & &1.last_poll)
      Agent.update(state, &Map.put(&1, :mode, :operations_closed))
      assert :continue = Runner.poll_once(runtime, "source", host)
      assert Host.ready?(host)
      Agent.update(state, &Map.put(&1, :mode, mode))
      assert ^action = Runner.poll_once(runtime, "source", host)
      refute Host.ready?(host)
      assert Agent.get(host.state, & &1.last_poll) == original
      assert Agent.get(host.state, & &1.operations) == %{}
      decisive = Agent.get(runtime.journal, &List.last(&1["details"])["evidence"])
      assert decisive["error_kind"] == kind
      assert decisive["proof"]["retained_authority"] == false
    end
  end

  test "owner loss or cancellation during either metadata GET cannot renew authority", context do
    for stage <- ["project", "operations"], failure <- [:owner, :cancel, :trust] do
      {runtime, host, state, fixture} = poll_fixture(context)
      Host.register(host, [operation("pending", "Creating instance", "websocket")])
      original = Agent.get(host.state, & &1.last_poll)

      owner =
        spawn(fn ->
          receive do
            :finish -> :ok
          after
            10_000 -> :ok
          end
        end)

      monitor = Process.monitor(owner)
      Agent.update(host.state, &%{&1 | owner: owner})
      scope = RequestContext.new!(timeout: 10_000)
      client = Incus.with_context(runtime.clients["source"], scope)

      client = %{
        client
        | context:
            Context.new!(
              owner: :poll_fixture,
              identity: :verified,
              ready?: fn -> Agent.get(state, &Map.get(&1, :approved, true)) end
            )
      }

      runtime = %{runtime | clients: %{"source" => client}}

      Agent.update(
        state,
        &Map.put(
          &1,
          :mode,
          if(stage == "project", do: :project_blocked, else: :operations_blocked)
        )
      )

      task = Task.async(fn -> Runner.poll_once(runtime, "source", host) end)
      assert_receive {:poll_blocked, ^stage, handler}, 2_000

      case failure do
        :owner ->
          Process.exit(owner, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

        :cancel ->
          RequestContext.cancel(scope)

        :trust ->
          Agent.update(state, &Map.put(&1, :approved, false))
      end

      send(handler, :release_poll)
      assert :stop = Task.await(task, 2_000)
      refute Host.ready?(host)
      assert Agent.get(host.state, & &1.last_poll) == original
      assert Agent.get(host.state, & &1.operations) == %{}
      decisive = Agent.get(runtime.journal, &List.last(&1["details"])["evidence"])
      kind = %{owner: :owner_lost, cancel: :canceled, trust: :host_not_ready}[failure]
      assert decisive["error_kind"] == Atom.to_string(kind)
      assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))

      if failure in [:owner, :cancel] do
        assert {:error, %Error{kind: ^kind}} =
                 Host.register(Map.put(host, :poll_context, scope), [
                   operation("must-not-renew", "Creating instance", "websocket")
                 ])

        assert Agent.get(host.state, & &1.last_poll) == original
      end

      if failure != :owner do
        send(owner, :finish)
        assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
      end
    end
  end

  defp poll_fixture(context) do
    {host, _} = host(context)
    observer = self()
    state = start_supervised!({Agent, fn -> %{mode: :ok} end}, id: make_ref())

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(context.root, "poll-#{System.unique_integer([:positive])}.sock"),
         handler: fn request ->
           mode = Agent.get(state, & &1.mode)

           case URI.parse(request.target).path do
             "/1.0" ->
               sync(%{
                 api_version: "1.0",
                 api_extensions: ["instances", "projects"],
                 environment: %{}
               })

             "/1.0/projects/project" when mode == :project_error ->
               poll_native_error()

             "/1.0/projects/project" when mode == :project_closed ->
               %{raw: ""}

             "/1.0/projects/project"
             when mode in [:project_truncated403, :project_truncated404] ->
               poll_truncated_status(mode)

             "/1.0/projects/project" when mode == :project_blocked ->
               await_poll_release(observer, "project")
               poll_project_response(:ok)

             "/1.0/projects/project" ->
               poll_project_response(mode)

             "/1.0/operations" when mode == :operations_error ->
               poll_native_error()

             "/1.0/operations" when mode == :operations_closed ->
               %{raw: ""}

             "/1.0/operations" when mode == :operations_blocked ->
               await_poll_release(observer, "operations")

               sync(%{
                 "running" => [operation("new-after-block", "Creating instance", "websocket")]
               })

             "/1.0/operations" when mode == :operations_invalid ->
               sync(%{"running" => "private-malformed"})

             "/1.0/operations" ->
               sync(%{"running" => []})
           end
         end},
        id: make_ref()
      )

    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :poll_fixture)

    {:ok, client} =
      Incus.connect(
        connection,
        Context.new!(
          owner: :poll_fixture,
          identity: :verified,
          ready?: fn -> true end
        )
      )

    journal = start_supervised!({Agent, fn -> %{"details" => []} end}, id: make_ref())

    runtime = %{
      clients: %{"source" => client},
      marker: "marker",
      journal: journal,
      config: %{
        "report" =>
          Path.join(context.root, "poll-report-#{System.unique_integer([:positive])}.json")
      }
    }

    {runtime, host, state, fixture}
  end

  defp poll_project_response(mode),
    do:
      sync(%{
        name: "project",
        config: %{},
        description:
          if(mode == :marker_changed,
            do: "private-foreign-marker",
            else: "Opsmaru gateway acceptance marker"
          )
      })

  defp poll_truncated_status(mode) do
    status = if mode == :project_truncated403, do: 403, else: 404
    %{raw: "HTTP/1.1 #{status} Fixture\r\nContent-Length: 20\r\n\r\nshort"}
  end

  defp await_poll_release(observer, stage) do
    send(observer, {:poll_blocked, stage, self()})

    receive do
      :release_poll -> :ok
    after
      5_000 -> raise "fixture release timeout"
    end
  end

  defp poll_native_error,
    do: %{
      status: 503,
      body: %{type: "error", error_code: 503, error: "private-error secret=private-secret"}
    }

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
          assert runtime.sides[side].client.connection.timeout == 5_000
          assert runtime.sides[side].host.freshness_ms == 12_000
          assert runtime.sides[side].host.operation_ttl_ms == 12_000
          assert runtime.sides[side].host.poll_interval_ms == 100
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

  test "a fresh --no-start subprocess bootstraps its own TLS hosts and cleans local listeners",
       context do
    {config, backend_state} = config(context)
    config_path = Path.join(context.root, "subprocess-config.json")
    File.write!(config_path, Jason.encode!(config))
    File.chmod!(config_path, 0o600)
    script = Path.join(context.root, "bootstrap.exs")
    source = Path.expand("../scripts/gateway-acceptance-host.exs", __DIR__)
    File.write!(script, bootstrap_script(source, config_path))

    {output, status} =
      System.cmd(
        "mise",
        ["exec", "--", "mix", "run", "--no-start", "--no-compile", "--no-deps-check", script],
        cd: Path.expand("..", __DIR__),
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 2:2"}]
      )

    assert status == 0, output
    assert output =~ "explicit-bootstrap-and-cleanup-passed"
    assert length(Agent.get(backend_state, & &1.posts)) == 2
    assert Jason.decode!(File.read!(config["report"]))["phase"] == "partial-resources-retained"
  end

  test "missing Ranch during cleanup cannot mask the original exit or skip local state cleanup",
       context do
    {config, backend_state} = config(context)
    config_path = Path.join(context.root, "cleanup-config.json")
    File.write!(config_path, Jason.encode!(config))
    File.chmod!(config_path, 0o600)
    script = Path.join(context.root, "cleanup-exit.exs")
    source = Path.expand("../scripts/gateway-acceptance-host.exs", __DIR__)
    File.write!(script, cleanup_failure_script(source, config_path))

    {output, status} =
      System.cmd(
        "mise",
        ["exec", "--", "mix", "run", "--no-start", "--no-compile", "--no-deps-check", script],
        cd: Path.expand("..", __DIR__),
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 2:2"}]
      )

    assert status == 0, output
    assert output =~ "cleanup-preserved-original-exit"
    assert map_size(Agent.get(backend_state, & &1.projects)) == 2
    assert Jason.decode!(File.read!(config["report"]))["phase"] == "failed-resources-retained"
  end

  test "scenario exits retain resources, record sanitized failure kind and preserve original reason",
       context do
    {config, backend_state} = config(context)
    reason = {:original_exit, "private-sentinel"}
    assert catch_exit(Runner.run(config, fn _ -> exit(reason) end)) == reason
    report = Jason.decode!(File.read!(config["report"]))
    assert report["phase"] == "failed-resources-retained"
    assert report["failure"] == "exit"
    refute File.read!(config["report"]) =~ "private-sentinel"
    assert map_size(Agent.get(backend_state, & &1.projects)) == 2

    for side <- ~w(source target),
        do: await_closed(URI.parse(config[side]["gateway"]["https"]).port)
  end

  test "scenario throws retain resources and preserve original thrown value", context do
    {config, backend_state} = config(context)
    reason = {:original_throw, "private-sentinel"}
    assert catch_throw(Runner.run(config, fn _ -> throw(reason) end)) == reason
    report = Jason.decode!(File.read!(config["report"]))
    assert report["phase"] == "failed-resources-retained"
    assert report["failure"] == "throw"
    refute File.read!(config["report"]) =~ "private-sentinel"
    assert map_size(Agent.get(backend_state, & &1.projects)) == 2
  end

  defp cleanup_failure_script(source, config_path) do
    """
    nil = Process.whereis(:ranch_sup)
    Code.require_file(#{inspect(source)})
    config = #{inspect(config_path)} |> File.read!() |> Jason.decode!()
    original = {:original_exit, "private-sentinel"}
    observed = try do
      OpsmaruGatewayAcceptance.run(config, fn runtime ->
        owned = for {_, side} <- runtime.sides, pid <- [side.host.state, side.gateway.admission], do: pid
        Process.put(:owned_local_state, owned)
        :ok = Application.stop(:ranch)
        exit(original)
      end)
    catch
      :exit, reason -> reason
    end
    true = observed == original
    true = Enum.all?(Process.get(:owned_local_state), &(not Process.alive?(&1)))
    report = config["report"] |> File.read!() |> Jason.decode!()
    "failed-resources-retained" = report["phase"]
    "exit" = report["failure"]
    false = String.contains?(File.read!(config["report"]), "private-sentinel")
    IO.puts("cleanup-preserved-original-exit")
    """
  end

  defp bootstrap_script(source, config_path) do
    """
    nil = Process.whereis(:ranch_sup)
    Code.require_file(#{inspect(source)})
    nil = Process.whereis(:ranch_sup)
    try do
      OpsmaruGatewayAcceptance.run(%{"allow_namespaced_mutations" => false}, fn _ -> raise "unapproved scenario ran" end)
    rescue
      ArgumentError -> :ok
    end
    nil = Process.whereis(:ranch_sup)
    config = #{inspect(config_path)} |> File.read!() |> Jason.decode!()
    report = OpsmaruGatewayAcceptance.run(config, fn runtime ->
      true = is_pid(Process.whereis(:ranch_sup))
      started = Enum.map(Application.started_applications(), &elem(&1, 0))
      true = Enum.all?([:ssl, :plug_cowboy, :cowboy, :ranch], &(&1 in started))
      for side <- ["source", "target"] do
        gateway = config[side]["gateway"]
        port = URI.parse(runtime.sides[side].origin).port
        tls = [verify: :verify_peer, cacertfile: String.to_charlist(gateway["server_ca"]),
          certfile: String.to_charlist(gateway["client_certificate"]), keyfile: String.to_charlist(gateway["client_key"]),
          server_name_indication: ~c"localhost"]
        response = Opsmaru.TestSupport.RawHTTP.request(port, "GET", "/1.0?project=" <> config[side]["project"], [], "", tls)
        200 = response.status
      end
    end)
    "partial-resources-retained" = report["phase"]
    closed = fn recur, port, remaining ->
      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
        {:error, :econnrefused} -> :ok
        {:ok, socket} when remaining > 0 -> :gen_tcp.close(socket); Process.sleep(10); recur.(recur, port, remaining - 1)
        {:error, :econnreset} when remaining > 0 -> Process.sleep(10); recur.(recur, port, remaining - 1)
        _ -> raise "acceptance listener did not close"
      end
    end
    for side <- ["source", "target"], do: closed.(closed, URI.parse(config[side]["gateway"]["https"]).port, 100)
    IO.puts("explicit-bootstrap-and-cleanup-passed")
    """
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

      {:error, :econnreset} ->
        # macOS may reset an in-flight connect while Ranch is closing. Keep
        # checking until the listener actually refuses new connections.
        Process.sleep(10)
        await_closed(port, remaining - 1)

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
