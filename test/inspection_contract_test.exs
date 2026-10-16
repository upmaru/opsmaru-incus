defmodule Opsmaru.Incus.InspectionContractTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, RequestContext, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}

  @names ~w(GetProjects GetProject GetProfiles GetProfile GetNetworks GetNetwork GetStoragePools GetStoragePool GetStoragePoolVolumes GetStoragePoolVolume GetInstances GetInstance GetInstanceState GetInstanceSnapshots GetInstanceSnapshot GetImages GetImage GetOperations GetOperation)
  @methods Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
           |> Enum.filter(&(&1["name"] in @names))
  # Discovery is a public helper, not a named Go GetServer DTO comparison.
  @discovery %{"name" => "connect", "params" => [], "result" => "discovery", "model" => "Server"}
  @contracts @methods ++ [@discovery]
  @extensions ~w(projects network storage)
  @driver Path.expand("../.integration/inspection-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert length(@methods) == 19
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

      bounds(root, identity, method)
      for mode <- [:deadline, :cancel], do: lifetime(root, identity, method, mode)
    end
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
    assert query["project"] == "fixture scope" and query["target"] == "member/a"

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

      outcome == :corrupt ->
        assert expected["error"]
        assert {:error, %Error{kind: :invalid_model}} = actual

      true ->
        refute expected["error"], inspect(expected)
        assert {:ok, reply} = actual
        assert reply.connection == client.connection and reply.identity == :verified
        assert reply.etag == "\"read-etag\""
        if method["result"] == "model", do: assert(reply.etag == Enum.at(expected["outputs"], 1))
        payload = flatten(method, metadata(method, outcome))

        decoded =
          if method["result"] in ["list", "grouped_list"],
            do: reply.metadata |> Enum.map(& &1.data) |> ordered(method),
            else: reply.metadata.data

        assert decoded == payload
        # The native typed DTO drops unknown fields; lossless retention is independent evidence.
        known = fn data -> Map.delete(data, "future_field") end

        if method["result"] in ["list", "grouped_list"] do
          native = ordered(hd(expected["outputs"]), method)

          assert Enum.zip(native, payload)
                 |> Enum.all?(fn {native, data} ->
                   Map.take(native, Map.keys(known.(data))) == known.(data)
                 end)

          assert length(hd(expected["outputs"])) == length(payload)
        else
          assert Map.take(hd(expected["outputs"]), Map.keys(known.(payload))) == known.(payload)
        end
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
  defp metadata(%{"result" => "list"}, :empty), do: []
  defp metadata(_, :empty), do: %{}

  defp metadata(method, outcome) do
    data = if outcome == :corrupt, do: corrupt(method["model"]), else: sample(method["model"])

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
