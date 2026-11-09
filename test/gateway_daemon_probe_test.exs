Code.require_file(Path.expand("../scripts/gateway-acceptance-host.exs", __DIR__))
Code.require_file(Path.expand("../scripts/gateway-daemon-probe.exs", __DIR__))

defmodule Opsmaru.Incus.GatewayDaemonProbeTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Context, ServerTrust}
  alias Opsmaru.TestSupport.HTTPFixture
  alias OpsmaruGatewayDaemonProbe, as: Probe

  test "each receiver learns its opposite daemon's actual TLS peer, not a shared container address",
       context do
    {runtime, state} = runtime(context, %{})
    assert Probe.verify_and_activate(runtime) == %{"source" => true, "target" => true}
    assert peers(runtime, "source") == [{0, 0, 0, 0, 0, 0, 0, 1}]
    assert peers(runtime, "target") == [{127, 0, 0, 1}]
    posts = Agent.get(state, & &1.posts)
    assert length(posts) == 2

    assert Enum.all?(posts, fn {actor, body, query} ->
             body["type"] == "custom" and body["content_type"] == "filesystem" and
               body["description"] == runtime.marker and
               body["source"]["type"] == "migration" and body["source"]["mode"] == "pull" and
               Map.keys(body["source"]["secrets"]) |> Enum.sort() == ~w(control fs) and
               query["project"] == runtime.config[actor]["project"]
           end)

    report = Jason.decode!(File.read!(runtime.config["report"]))
    refute File.read!(runtime.config["report"]) =~ "secret="
    assert Enum.any?(report["details"], &(&1["step"] == "daemon-probe-accepted/source"))
    assert Agent.get(state, & &1.deletes) == 0
  end

  test "unreachable daemon clears only that receiver's authority and never guesses container peer",
       context do
    {runtime, state} = runtime(context, %{"target" => :no_dial})
    assert Probe.verify_and_activate(runtime) == %{"source" => false, "target" => true}
    assert peers(runtime, "source") == []
    assert peers(runtime, "target") == [{127, 0, 0, 1}]
    assert Agent.get(state, & &1.deletes) == 0
  end

  test "wrong nonce or secret cannot establish daemon peer proof", context do
    {runtime, _} = runtime(context, %{"target" => :wrong_secret, "source" => :wrong_path})
    assert Probe.verify_and_activate(runtime) == %{"source" => false, "target" => false}
    assert peers(runtime, "source") == []
    assert peers(runtime, "target") == []
  end

  test "a nonce match without authoritative terminal failure grants no peer and sends no cancel",
       context do
    {runtime, state} = runtime(context, %{"target" => :never_terminal})
    assert Probe.verify_and_activate(runtime) == %{"source" => false, "target" => true}
    assert peers(runtime, "source") == []
    assert Agent.get(state, & &1.deletes) == 0
    report = Jason.decode!(File.read!(runtime.config["report"]))

    assert Enum.any?(report["details"], fn entry ->
             entry["step"] == "daemon-probe-result/source" and
               entry["evidence"]["native_status"] == "deadline"
           end)
  end

  test "project volume feature mismatch prevents every probe POST", context do
    {runtime, state} = runtime(context, %{"target" => :wrong_project_feature})
    assert_raise MatchError, fn -> Probe.verify_and_activate(runtime) end
    assert Agent.get(state, & &1.posts) == []
    assert peers(runtime, "source") == []
    assert peers(runtime, "target") == []
  end

  test "standalone probe refuses missing mutation opt-in or a default project", context do
    {runtime, state} = runtime(context, %{})

    for config <- [
          Map.put(runtime.config, "allow_namespaced_mutations", false),
          put_in(runtime.config, ["source", "project"], "default")
        ] do
      assert_raise MatchError, fn -> Probe.verify_and_activate(%{runtime | config: config}) end
    end

    assert_raise ArgumentError, "invalid bounded daemon probe timeout", fn ->
      Probe.verify_and_activate(%{
        runtime
        | config: Map.put(runtime.config, "daemon_probe_timeout_ms", 0)
      })
    end

    assert Agent.get(state, & &1.posts) == []
  end

  defp peers(runtime, side), do: Agent.get(runtime.sides[side].host.state, & &1.verified_peers)

  defp runtime(context, modes) do
    state =
      start_supervised!({Agent, fn -> %{posts: [], statuses: %{}, deletes: 0} end},
        id: make_ref()
      )

    client_identity = TLSIdentity.generate(context.root, "probe-client", "caller")
    marker = "fixture-run-marker"

    configs =
      for side <- ~w(source target), into: %{} do
        server = TLSIdentity.generate(context.root, "probe-receiver-" <> side, "localhost")

        fixture =
          start_supervised!(
            {HTTPFixture,
             transport: :gen_tcp,
             path: Path.join(context.root, "daemon-" <> side),
             handler: &respond(&1, side, marker, state, modes)},
            id: make_ref()
          )

        backend_context =
          Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)

        {:ok, client} =
          Incus.connect(
            Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
            backend_context
          )

        config = %{
          "project" => "opsmaru-acceptance-gateway-" <> side,
          "pool" => "default",
          "gateway" => %{
            "https" => "https://localhost:8443",
            "bind_ip" => if(side == "source", do: "::1", else: "127.0.0.1"),
            "server_certificate" => server.certfile,
            "server_key" => server.keyfile,
            "client_ca" => client_identity.cafile
          }
        }

        host_state =
          start_supervised!({Agent, fn -> %{verified_peers: [{203, 0, 113, 9}]} end},
            id: make_ref()
          )

        {side, %{config: config, client: client, host_state: host_state}}
      end

    report = Path.join(context.root, "daemon-report.json")
    File.write!(report, "{}")
    File.chmod!(report, 0o600)
    journal = start_supervised!({Agent, fn -> %{"details" => []} end}, id: make_ref())

    config =
      Map.merge(Map.new(configs, fn {side, entry} -> {side, entry.config} end), %{
        "report" => report,
        "daemon_probe_timeout_ms" => 1_000,
        "allow_namespaced_mutations" => true
      })

    clients = Map.new(configs, fn {side, entry} -> {side, entry.client} end)

    sides =
      Map.new(configs, fn {side, entry} ->
        {side,
         %{
           client: Incus.project(entry.client, entry.config["project"]),
           host: %{state: entry.host_state}
         }}
      end)

    {%{
       config: config,
       clients: clients,
       sides: sides,
       journal: journal,
       marker: marker,
       resource_prefix: "gw-fixture-"
     }, state}
  end

  defp respond(request, side, marker, state, modes) do
    uri = URI.parse(request.target)

    cond do
      uri.path == "/1.0" ->
        sync(%{api_version: "1.0", api_extensions: ~w(projects storage), environment: %{}})

      String.starts_with?(uri.path, "/1.0/projects/") ->
        sync(%{
          name: "opsmaru-acceptance-gateway-" <> side,
          description: "Opsmaru gateway acceptance " <> marker,
          config: %{
            "features.storage.volumes" =>
              if(modes[side] == :wrong_project_feature, do: "false", else: "true")
          }
        })

      request.method == "POST" ->
        body = Jason.decode!(request.body)
        id = "probe-" <> side

        Agent.update(
          state,
          &%{
            &1
            | posts: [{side, body, URI.decode_query(uri.query || "")} | &1.posts],
              statuses: Map.put(&1.statuses, id, 103)
          }
        )

        spawn(fn ->
          if modes[side] != :no_dial, do: daemon_dial(body, side, modes[side])

          unless modes[side] == :never_terminal,
            do: Agent.update(state, &%{&1 | statuses: Map.put(&1.statuses, id, 400)})
        end)

        %{
          status: 202,
          body: %{
            type: "async",
            status_code: 100,
            operation: "/1.0/operations/" <> id,
            metadata: %{id: id, class: "task", status_code: 103, metadata: %{}}
          }
        }

      String.starts_with?(uri.path, "/1.0/operations/") ->
        id = String.replace_prefix(uri.path, "/1.0/operations/", "")

        sync(%{
          id: id,
          class: "task",
          status_code: Agent.get(state, &Map.fetch!(&1.statuses, id)),
          err: "expected negative migration"
        })

      request.method == "DELETE" ->
        Agent.update(state, &%{&1 | deletes: &1.deletes + 1})
        sync(%{})

      true ->
        %{status: 404, body: %{type: "error", error_code: 404, error: "not found"}}
    end
  end

  defp daemon_dial(body, side, mode) do
    uri = URI.parse(body["source"]["operation"])
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(body["source"]["certificate"])

    options = [
      :binary,
      if(side == "target", do: :inet6, else: :inet),
      active: false,
      ip: if(side == "source", do: {127, 0, 0, 1}, else: {0, 0, 0, 0, 0, 0, 0, 1}),
      verify: :verify_peer,
      cacerts: [],
      server_name_indication: ~c"localhost",
      verify_fun:
        {&ServerTrust.verify/3,
         %{digest: :crypto.hash(:sha256, der), hostname: "localhost", ca: false}}
    ]

    {:ok, socket} = :ssl.connect(~c"localhost", uri.port, options, 3_000)

    path =
      if mode == :wrong_path,
        do: "/1.0/operations/wrong/websocket",
        else: uri.path <> "/websocket"

    secret = if mode == :wrong_secret, do: "wrong", else: body["source"]["secrets"]["control"]

    :ok =
      :ssl.send(
        socket,
        RawHTTP.head("GET", path <> "?secret=" <> URI.encode_www_form(secret), [
          {"connection", "upgrade"},
          {"upgrade", "websocket"}
        ])
      )

    assert {:ok, response} = :ssl.recv(socket, 0, 3_000)
    assert response =~ "403 Forbidden"
    :ssl.close(socket)
  end

  defp sync(metadata),
    do: %{
      status: 200,
      body: %{type: "sync", status: "Success", status_code: 200, metadata: metadata}
    }
end
