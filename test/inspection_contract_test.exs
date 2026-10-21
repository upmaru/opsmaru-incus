defmodule Opsmaru.Incus.InspectionContractTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, RequestContext, Server, Transport}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}

  @names ~w(GetProjects GetProject GetProfiles GetProfile GetNetworks GetNetwork GetStoragePools GetStoragePool GetStoragePoolVolumes GetStoragePoolVolume GetInstances GetInstance GetInstanceState GetInstanceSnapshots GetInstanceSnapshot GetImages GetImage GetOperations GetOperation)
  # B02 PR 1: every other method mapped to the instance, image and operation rows.
  @b02 ~w(GetImageFingerprints GetImagesWithFilter GetImagesAllProjects GetImagesAllProjectsWithFilter GetPrivateImage GetInstanceNames GetInstanceNamesAllProjects GetInstancesWithFilter GetInstancesAllProjects GetInstancesAllProjectsWithFilter GetInstancesFull GetInstancesFullWithFilter GetInstancesFullAllProjects GetInstancesFullAllProjectsWithFilter GetInstanceFull GetInstanceSnapshotNames GetOperationUUIDs GetOperationsAllProjects)
  # B02 PR 2: every other method mapped to the project, profile, network and storage rows.
  @b02_storage ~w(GetProjectNames GetProjectsWithFilter GetProfileNames GetProfilesWithFilter GetProfilesAllProjects GetProfilesAllProjectsWithFilter GetNetworkNames GetNetworksWithFilter GetNetworksAllProjects GetNetworksAllProjectsWithFilter GetStoragePoolNames GetStoragePoolsWithFilter GetStoragePoolVolumesWithFilter GetStoragePoolVolumesFull GetStoragePoolVolumesFullWithFilter GetStoragePoolVolumeNames GetStoragePoolVolumesAllProjects GetStoragePoolVolumesWithFilterAllProjects GetStoragePoolVolumesFullAllProjects GetStoragePoolVolumesFullWithFilterAllProjects GetStoragePoolVolumeNamesAllProjects GetStoragePoolVolumeFull)
  # B09 PR 1: every read method mapped to the network rows.
  @b09 ~w(GetNetworkACLNames GetNetworkACLs GetNetworkACLsAllProjects GetNetworkACL GetNetworkAddressSetNames GetNetworkAddressSets GetNetworkAddressSetsAllProjects GetNetworkAddressSet GetNetworkAllocations GetNetworkAllocationsAllProjects GetNetworkIntegrationNames GetNetworkIntegrations GetNetworkIntegration GetNetworkZoneNames GetNetworkZones GetNetworkZonesAllProjects GetNetworkZone GetNetworkZoneRecords GetNetworkZoneRecordNames GetNetworkZoneRecord GetNetworkForwards GetNetworkForwardAddresses GetNetworkForward GetNetworkLeases GetNetworkLoadBalancerAddresses GetNetworkLoadBalancers GetNetworkLoadBalancer GetNetworkLoadBalancerState GetNetworkPeers GetNetworkPeerNames GetNetworkPeer GetNetworkState)
  @methods Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
           |> Enum.filter(&(&1["name"] in (@names ++ @b02 ++ @b02_storage ++ @b09)))
  # Models without a hand-written sample get a schema-driven one (see generate/2).
  @models Jason.decode!(File.read!("priv/incus/models.json"))["models"]
  @generated ~w(NetworkACL NetworkAddressSet NetworkAllocations NetworkForward NetworkIntegration NetworkLease NetworkLoadBalancer NetworkLoadBalancerState NetworkPeer NetworkState NetworkZone NetworkZoneRecord)
  # Discovery is a public helper, not a named Go GetServer DTO comparison.
  @discovery %{"name" => "connect", "params" => [], "result" => "discovery", "model" => "Server"}
  @contracts @methods ++ [@discovery]
  @extensions ~w(projects network storage api_filtering container_full images_all_projects instance_all_projects instance_get_full operations_get_query_all_projects networks_all_projects profiles_all_projects storage_volume_full storage_volumes_all_projects network_acl network_acls_all_projects network_address_set network_allocations network_dns network_dns_records network_forward network_integrations network_leases network_load_balancer network_load_balancer_state network_peer network_state network_zones_all_projects)
  @driver Path.expand("../.integration/inspection-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert length(@methods) == 91
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-read-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for method <- @contracts, transport <- [:unix, :https] do
    test "#{method["name"]} #{transport} scoped inspection matches native results, routing and errors",
         %{root: root} do
      method = unquote(Macro.escape(method))

      identity =
        if unquote(transport) == :https, do: TLSIdentity.generate(root, "read", "localhost")

      for outcome <- [:populated, :empty, :corrupt, 403, 404],
          do: compare(root, identity, method, outcome)

      if method == @discovery do
        for outcome <- [:missing, :version], do: compare(root, identity, method, outcome)
      end

      # The daemon groups operation URLs by status; a flat list stays accepted too.
      if method["name"] == "GetOperationUUIDs", do: compare(root, identity, method, :flat)

      if method["result"] == "names" do
        malformed = if method["name"] == "GetOperationUUIDs", do: :nested, else: :grouped
        compare(root, identity, method, malformed)
      end

      if method["model"] == "StorageVolumeFull",
        do: compare(root, identity, method, :corrupt_backup)

      bounds(root, identity, method)
      for mode <- [:deadline, :cancel], do: lifetime(root, identity, method, mode)
    end
  end

  for transport <- [:unix, :https] do
    test "#{transport} socket receive expiry retains deadline despite delayed observation", %{
      root: root
    } do
      identity =
        if unquote(transport) == :https, do: TLSIdentity.generate(root, "expiry", "localhost")

      for method <- ["GET", "HEAD", "POST"], do: receive_expiry(root, identity, method)
    end
  end

  defp receive_expiry(root, identity, method) do
    parent = self()
    tag = make_ref()

    fixture =
      backend(
        root,
        identity,
        fn request ->
          %{
            upgrade: fn transport, socket ->
              if URI.parse(request.target).path == "/1.0/stalled" do
                send(parent, {tag, :entered})
                send(parent, {tag, :closed, transport.recv(socket, 0, 30_000)})
              end
            end
          }
        end,
        @discovery
      )

    original = client(fixture, identity)
    context = RequestContext.new!(timeout: 3_000)
    scoped = Incus.with_context(original, context)

    caller =
      spawn(fn ->
        receive do
          :start -> send(parent, {tag, Incus.raw_query(scoped, method, "/1.0/stalled")})
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    patterns = [{Mint.HTTP, :recv, 3}, {Transport, :receive_response, 5}]

    for {module, _, _} = pattern <- patterns do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(pattern, [{:_, [], [{:return_trace}]}], [:local]) == 1
    end

    on_exit(fn ->
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
    end)

    :erlang.trace(caller, true, [:call, :procs, :set_on_spawn])
    send(caller, :start)
    assert_receive {:trace, ^caller, :spawn, worker, _}, 10_000
    assert_receive {:trace, ^worker, :spawn, guard, _}, 10_000

    on_exit(fn ->
      for pid <- [worker, guard], Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    for pid <- [caller, worker, guard], do: :erlang.trace(pid, false, [:procs, :set_on_spawn])
    # Force the actual socket timeout to win; neither competing observer can end the worker.
    assert :erlang.suspend_process(guard)
    assert :erlang.suspend_process(caller)
    monitor = Process.monitor(worker)
    assert_receive {^tag, :entered}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 10_000
    assert_receive {^tag, :closed, {:error, :closed}}, 10_000

    assert_receive {:trace, ^worker, :return_from, {Mint.HTTP, :recv, 3},
                    {:error, _, %Mint.TransportError{reason: :timeout}, []}},
                   10_000

    assert_receive {:trace, ^worker, :return_from, {Transport, :receive_response, 5}, classified},
                   10_000

    assert classified == {:error, :deadline}
    assert :erlang.resume_process(caller)
    expected = if method in ["GET", "HEAD"], do: :deadline, else: :uncertain
    assert_receive {^tag, result}, 10_000
    assert {:error, %Error{kind: ^expected}} = result
    assert RequestContext.status(context) == :deadline
    assert original.connection.request_context == nil

    # An early peer EOF is still a response failure, not a synthetic deadline.
    eof_kind = if method in ["GET", "HEAD"], do: :response, else: :uncertain
    assert {:error, %Error{kind: ^eof_kind}} = Incus.raw_query(original, method, "/1.0/eof")
    assert [%{method: ^method}, %{method: ^method}] = HTTPFixture.requests(fixture)
  end

  defp compare(root, identity, method, outcome) do
    fixture = backend(root, identity, fn _ -> response(method, outcome) end, method)
    client = client(fixture, identity)
    values = Enum.map(method["params"], &args(method)[&1])

    input =
      Map.merge(native_connection(fixture, identity), %{
        action: method["name"],
        args: values,
        project: "fixture scope",
        target: "member/a"
      })

    input =
      if method == @discovery,
        do:
          input
          |> Map.drop([:action, :args])
          |> Map.merge(%{method: "GET", path: "/1.0?project=fixture+scope&target=member%2Fa"}),
        else: input

    file = Path.join(root, "oracle.json")
    File.write!(file, Jason.encode!(input))
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    expected = Jason.decode!(out)
    actual = invoke(client, method)
    requests = HTTPFixture.requests(fixture)
    if method != @discovery, do: assert(length(requests) == 3)
    assert [native, local] = if(method == @discovery, do: requests, else: tl(requests))
    assert local.method == "GET"
    assert WireComparison.request(local) == WireComparison.request(native)
    query = URI.decode_query(URI.parse(local.target).query)
    assert query["target"] == "member/a"

    # all-projects suppresses the connection project, as in the pinned client.
    if method["query"]["all-projects"],
      do: assert(query["all-projects"] == "true" and not Map.has_key?(query, "project")),
      else: assert(query["project"] == "fixture scope")

    assert_result(actual, expected, client, method, outcome)
  end

  defp assert_result(actual, expected, client, method, outcome) do
    cond do
      is_integer(outcome) ->
        assert {:error,
                %Error{
                  kind: :native,
                  http_status: ^outcome,
                  error_code: ^outcome,
                  response: reply,
                  message: message
                }} = actual

        assert expected["error_status"] == outcome and expected["error"] == message
        assert reply.connection == client.connection and reply.identity == :verified

      method == @discovery ->
        discovery_result(actual, expected, client, outcome)

      outcome in [:corrupt, :corrupt_backup, :grouped, :nested] ->
        assert expected["error"]
        assert {:error, %Error{kind: :invalid_model}} = actual

      method["result"] in ["names", "project_names", "project_urls"] ->
        names_result(actual, expected, client, method, outcome)

      true ->
        model_result(actual, expected, client, method, outcome)
    end
  end

  defp names_result(actual, expected, client, method, outcome) do
    assert {:ok, reply} = actual
    assert reply.connection == client.connection and reply.identity == :verified
    assert reply.metadata == names(method, outcome)

    # Approved difference: the pinned client cannot decode the daemon's grouped map.
    if method["name"] == "GetOperationUUIDs" and outcome in [:populated, :empty],
      do: assert(expected["error"]),
      else: assert(hd(expected["outputs"]) == reply.metadata)
  end

  defp model_result(actual, expected, client, method, outcome) do
    refute expected["error"], inspect(expected)
    assert {:ok, reply} = actual
    assert reply.connection == client.connection and reply.identity == :verified
    assert reply.etag == "\"read-etag\""
    # Some pinned getters (network and load-balancer state) return no ETag to compare.
    if method["result"] == "model" and length(expected["outputs"]) > 1,
      do: assert(reply.etag == Enum.at(expected["outputs"], 1))

    payload = flatten(method, metadata(method, outcome))
    listed? = method["result"] in ["list", "grouped_list"]

    decoded =
      if listed?,
        do: reply.metadata |> Enum.map(& &1.data) |> ordered(method),
        else: reply.metadata.data

    assert decoded == payload
    # The native typed DTO drops unknown fields; lossless retention is independent evidence.
    known = fn data -> Map.delete(data, "future_field") end

    if listed? do
      native = ordered(hd(expected["outputs"]), method)

      assert Enum.zip(native, payload)
             |> Enum.all?(fn {native, data} -> sent?(native, known.(data)) end)

      assert length(hd(expected["outputs"])) == length(payload)
    else
      assert sent?(hd(expected["outputs"]), known.(payload))
    end
  end

  defp bounds(root, identity, method) do
    fixture = backend(root, identity, fn _ -> response(method, :populated) end, method)
    client = client(fixture, identity)
    limited = %{client | connection: %{client.connection | max_response_bytes: 32}}

    assert {:error, %Error{kind: :response_limit}} =
             invoke(limited, method)

    for extension <- List.wrap(method["extension"]) do
      missing = %{client | server: %Server{api_extensions: List.delete(@extensions, extension)}}

      assert {:error, %Error{kind: :unsupported_extension}} =
               Incus.call(missing, method["name"], args(method))
    end

    unready = %{
      client
      | context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> false end)
    }

    assert {:error, %Error{kind: :host_not_ready}} = invoke(unready, method)
    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  defp lifetime(root, identity, method, mode) do
    parent = self()
    tag = make_ref()

    fixture =
      backend(
        root,
        identity,
        fn _ ->
          %{
            upgrade: fn transport, socket ->
              send(parent, {tag, :entered})
              send(parent, {tag, :closed, transport.recv(socket, 0, 30_000)})
            end
          }
        end,
        method
      )

    original = client(fixture, identity)
    context = RequestContext.new!(timeout: if(mode == :deadline, do: 3_000, else: 30_000))
    scoped = Incus.with_context(original, context)
    task = Task.async(fn -> invoke(scoped, method) end)
    assert_receive {^tag, :entered}, 10_000
    if mode == :cancel, do: RequestContext.cancel(context)
    kind = if mode == :deadline, do: :deadline, else: :canceled
    assert {:error, %Error{kind: ^kind}} = Task.await(task, 10_000)
    assert_receive {^tag, :closed, {:error, :closed}}, 10_000
    assert original.connection.request_context == nil
    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  defp response(_method, code) when is_integer(code),
    do: %{status: code, body: %{type: "error", error_code: code, error: "native read rejection"}}

  defp response(method, outcome),
    do: %{
      status: 200,
      headers: %{"ETag" => "\"read-etag\""},
      body: %{type: "sync", status_code: 200, metadata: metadata(method, outcome)}
    }

  defp invoke(client, @discovery), do: Incus.connect(client.connection, client.context)
  defp invoke(client, method), do: Incus.call(client, method["name"], args(method))

  defp discovery_result(actual, native, client, outcome) do
    refute native["error"]
    assert native["response"]["metadata"] == metadata(@discovery, outcome)
    assert native["etag"] == "\"read-etag\""

    if outcome in [:corrupt, :missing, :version] do
      kind = if outcome == :version, do: :unsupported_version, else: :invalid_server
      assert {:error, %Error{kind: ^kind}} = actual
    else
      assert {:ok, connected} = actual
      assert connected.connection == client.connection and connected.context == client.context
      assert connected.server.raw == metadata(@discovery, outcome)
      assert connected.server.api_version == "1.0"
      assert connected.server.api_extensions == metadata(@discovery, outcome)["api_extensions"]
    end
  end

  defp metadata(@discovery, :missing), do: %{}
  defp metadata(@discovery, :empty), do: %{"api_version" => "1.0", "api_extensions" => []}
  defp metadata(@discovery, :version), do: %{sample("Server") | "api_version" => "2.0"}

  # The daemon groups operation URLs by status, so its empty answer is an empty map.
  defp metadata(%{"name" => "GetOperationUUIDs"}, :empty), do: %{}

  defp metadata(%{"result" => result}, :empty)
       when result in ~w(list names project_names project_urls),
       do: []

  defp metadata(_, :empty), do: %{}

  defp metadata(%{"result" => "names"} = method, outcome) do
    prefix =
      String.replace(method["path"], ~r/\{[^}]+\}/, &("fixture-" <> String.slice(&1, 1..-2//1)))

    prefix = URI.encode(prefix)

    cond do
      outcome == :corrupt ->
        ["/1.0/unrelated/fixture"]

      # Only operation UUIDs are grouped; other names reject a map or nested groups.
      outcome == :grouped ->
        %{"running" => [prefix <> "/fixture"]}

      outcome == :nested ->
        %{"running" => [[prefix <> "/running"]]}

      method["name"] == "GetOperationUUIDs" and outcome == :populated ->
        %{"running" => [prefix <> "/running"], "success" => [prefix <> "/finished"]}

      method["name"] == "GetOperationUUIDs" ->
        [prefix <> "/running", prefix <> "/finished"]

      # Volume URLs carry their type; names keep the type/name path.
      String.ends_with?(method["path"], "/volumes") ->
        [prefix <> "/custom/fixture", prefix <> "/custom/second%20one"]

      true ->
        [prefix <> "/fixture", prefix <> "/second%20one"]
    end
  end

  defp metadata(%{"result" => "project_urls"}, :corrupt), do: ["/1.0/unrelated/fixture"]

  # Volume URLs across projects: the project query names the group (default when absent).
  defp metadata(%{"result" => "project_urls"} = method, _) do
    prefix = String.replace(method["path"], "{pool}", "fixture-pool")

    [
      prefix <> "/custom/fixture",
      prefix <> "/custom/second?project=fixture%20scope",
      prefix <> "/custom/third?project=fixture%20scope"
    ]
  end

  defp metadata(%{"result" => "project_names"}, :corrupt), do: [%{"name" => 1}]

  defp metadata(%{"result" => "project_names"}, _),
    do: [
      %{"name" => "fixture", "project" => "default"},
      %{"name" => "second", "project" => "fixture scope"},
      %{"name" => "third", "project" => "fixture scope"}
    ]

  defp metadata(method, outcome) do
    data =
      case outcome do
        :corrupt -> corrupt(method["model"])
        :corrupt_backup -> corrupt(method["model"] <> " backup")
        _ -> sample(method["model"])
      end

    case method["result"] do
      "list" ->
        [data]

      "grouped_list" ->
        %{
          "running" => [data],
          "success" => [%{data | "id" => "finished", "status" => "Success", "status_code" => 200}]
        }

      _ ->
        data
    end
  end

  # Decoded names for each fixture shape (grouped operation URLs flatten by status).
  defp names(%{"result" => result}, :empty) when result in ~w(project_names project_urls),
    do: %{}

  defp names(_, :empty), do: []

  defp names(%{"result" => "project_names"}, _),
    do: %{"default" => ["fixture"], "fixture scope" => ["second", "third"]}

  defp names(%{"result" => "project_urls"}, _),
    do: %{"default" => ["custom/fixture"], "fixture scope" => ["custom/second", "custom/third"]}

  defp names(%{"name" => "GetOperationUUIDs"}, _), do: ["running", "finished"]

  defp names(%{"path" => path}, _) when binary_part(path, byte_size(path) - 8, 8) == "/volumes",
    do: ["custom/fixture", "custom/second one"]

  defp names(_, _), do: ["fixture", "second one"]

  # Schema-driven sample: every field gets a typed non-zero value; nested structs,
  # pointers, lists and maps recurse, bounded in depth.
  defp generate(model, depth) do
    Map.new(@models[model]["fields"], fn field ->
      {field["name"], value(field["type"], field["name"], depth)}
    end)
  end

  defp value("*" <> type, name, depth), do: value(type, name, depth)
  defp value("[]string", name, _), do: ["fixture-" <> name]

  defp value("[]" <> type, name, depth),
    do: if(depth < 3, do: [value(type, name, depth + 1)], else: [])

  defp value("map[string]" <> type, name, depth),
    do: if(depth < 3, do: %{"fixture" => value(type, name, depth + 1)}, else: %{})

  defp value("string", name, _), do: "fixture-" <> name
  defp value("bool", _, _), do: true
  defp value(type, _, _) when type in ~w(int int64 uint64), do: 7
  defp value("ConfigMap", _, _), do: %{"user.fixture" => "value"}
  defp value(type, _, depth) when is_map_key(@models, type), do: generate(type, depth + 1)

  # Every field the fixture sent survives in the native DTO at every depth; the
  # DTO may add zero-valued fields the fixture omitted.
  defp sent?(native, sent) when is_map(sent),
    do: is_map(native) and Enum.all?(sent, fn {key, value} -> sent?(native[key], value) end)

  defp sent?(native, sent) when is_list(sent),
    do:
      is_list(native) and length(native) == length(sent) and
        Enum.all?(Enum.zip(native, sent), fn {n, v} -> sent?(n, v) end)

  defp sent?(native, sent), do: native == sent

  defp flatten(%{"result" => "grouped_list"} = method, groups),
    do: groups |> Map.values() |> List.flatten() |> ordered(method)

  defp flatten(_, data), do: data

  # The Go client flattens a map of groups; cross-group result ordering is not a contract.
  defp ordered(data, %{"result" => "grouped_list"}), do: Enum.sort_by(data, & &1["id"])
  defp ordered(data, _), do: data

  defp corrupt("Server"), do: %{"api_version" => "1.0", "api_extensions" => false}
  defp corrupt("InstanceState"), do: %{"pid" => "invalid"}
  defp corrupt("Image"), do: %{"public" => "invalid"}
  defp corrupt("Operation"), do: %{sample("Operation") | "status_code" => "invalid"}
  # Full volumes prove each nested collection rejects a malformed item on its own.
  defp corrupt("StorageVolumeFull"),
    do: %{sample("StorageVolumeFull") | "snapshots" => [%{"name" => 1}]}

  defp corrupt("StorageVolumeFull backup"),
    do: %{sample("StorageVolumeFull") | "backups" => [%{"volume_only" => "yes"}]}

  # A generated model breaks its first string field (or, without one, gives its first
  # collection field a string), which the pinned DTO rejects.
  defp corrupt(model) when model in @generated do
    fields = @models[model]["fields"]

    case Enum.find(fields, &(&1["type"] == "string")) do
      %{"name" => name} ->
        %{sample(model) | name => 7}

      nil ->
        %{"name" => name} = Enum.find(fields, &String.starts_with?(&1["type"], ["map[", "[]"]))
        %{sample(model) | name => "invalid"}
    end
  end

  defp corrupt(_), do: %{"config" => []}

  defp sample("Server"),
    do: %{
      "api_version" => "1.0",
      "api_extensions" => @extensions,
      "api_status" => "stable",
      "auth" => "trusted",
      "environment" => %{},
      "future_field" => %{}
    }

  defp sample("InstanceState"),
    do: %{
      "status" => "Running",
      "status_code" => 103,
      "pid" => 42,
      "processes" => 2,
      "memory" => %{
        "usage" => 32,
        "usage_peak" => 0,
        "total" => 0,
        "swap_usage" => 0,
        "swap_usage_peak" => 0
      },
      "future_field" => %{}
    }

  defp sample("Image"),
    do: %{
      "fingerprint" => "fixture-fingerprint",
      "public" => false,
      "auto_update" => false,
      "properties" => %{"description" => "fixture"},
      "size" => 123,
      "architecture" => "x86_64",
      "future_field" => %{}
    }

  defp sample("Operation"),
    do: %{
      "id" => "running",
      "status" => "Running",
      "status_code" => 103,
      "err" => "",
      "may_cancel" => true,
      "metadata" => %{"fixture" => "retained"},
      "future_field" => %{}
    }

  defp sample("StorageVolumeFull"),
    do:
      Map.merge(sample("StorageVolume"), %{
        "state" => %{"usage" => %{"used" => 42, "total" => 100}},
        "snapshots" => [
          %{
            "name" => "snap0",
            "description" => "nested",
            "config" => %{"size" => "1GiB"},
            "content_type" => "filesystem",
            "created_at" => "2026-10-20T12:00:00Z",
            "expires_at" => "2026-11-20T12:00:00Z"
          }
        ],
        "backups" => [
          %{
            "name" => "backup0",
            "created_at" => "2026-10-20T12:00:00Z",
            "expires_at" => "2026-11-20T12:00:00Z",
            "volume_only" => true,
            "optimized_storage" => false
          }
        ]
      })

  defp sample("InstanceFull"),
    do:
      Map.merge(sample("Instance"), %{
        "state" => Map.delete(sample("InstanceState"), "future_field"),
        "snapshots" => [Map.delete(sample("InstanceSnapshot"), "future_field")],
        "backups" => []
      })

  defp sample(model) when model in ["Instance", "InstanceSnapshot"] do
    base = %{
      "name" => "fixture",
      "config" => %{"user.note" => "value"},
      "devices" => %{"root" => %{"type" => "disk", "path" => "/", "pool" => "fixture"}},
      "profiles" => ["default"],
      "future_field" => %{}
    }

    if model == "Instance",
      do: Map.merge(base, %{"type" => "container", "status" => "Running", "status_code" => 103}),
      else: Map.put(base, "stateful", false)
  end

  defp sample(model) when model in @generated,
    do: Map.put(generate(model, 0), "future_field", %{})

  defp sample(model) do
    base = %{
      "name" => "fixture",
      "description" => "inspection",
      "config" => %{"user.note" => "value"},
      "used_by" => [],
      "future_field" => %{}
    }

    case model do
      "Profile" ->
        Map.put(base, "devices", %{
          "root" => %{"type" => "disk", "path" => "/", "pool" => "fixture"}
        })

      "Network" ->
        Map.merge(base, %{"type" => "bridge", "managed" => true, "locations" => ["member-a"]})

      "StoragePool" ->
        Map.merge(base, %{"driver" => "dir", "status" => "Created", "locations" => ["member-a"]})

      "StorageVolume" ->
        Map.merge(base, %{
          "type" => "custom",
          "content_type" => "filesystem",
          "project" => "fixture scope",
          "location" => "member-a"
        })

      "Project" ->
        base
    end
  end

  defp args(method),
    do:
      Map.new(
        method["params"],
        &{&1,
         case &1 do
           "volType" -> "custom"
           "instance_type" -> "container"
           "filters" -> ["name=fixture", "status=Running"]
           key -> "fixture-" <> key
         end}
      )

  defp backend(root, identity, handler, method) do
    options =
      if identity,
        do: [
          transport: :ssl,
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            cacertfile: identity.cafile,
            verify: :verify_peer,
            fail_if_no_peer_cert: true
          ]
        ],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "s#{System.unique_integer([:positive])}")
        ]

    start_supervised!(
      {HTTPFixture,
       options ++
         [
           handler: fn request ->
             if method != @discovery and URI.parse(request.target).path == "/1.0",
               do: %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{api_version: "1.0", api_extensions: @extensions, environment: %{}}
                 }
               },
               else: handler.(request)
           end
         ]},
      id: make_ref()
    )
  end

  defp client(fixture, identity) do
    endpoint = HTTPFixture.endpoint(fixture)
    options = [owner: :fixture, project: "fixture scope", member: "member/a", timeout: 30_000]

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            options ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, options)

    %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: @extensions}
    }
  end

  defp native_connection(fixture, nil), do: %{socket: HTTPFixture.endpoint(fixture).socket}

  defp native_connection(fixture, identity),
    do: %{
      url: HTTPFixture.endpoint(fixture).url,
      tls_ca: File.read!(identity.cafile),
      client_cert: File.read!(identity.certfile),
      client_key: File.read!(identity.keyfile)
    }
end
