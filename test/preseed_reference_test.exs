defmodule Opsmaru.Incus.PreseedReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Preseed}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}
  @driver Path.expand("../../.integration/incus-preseed-driver", __DIR__)
  @extensions ~w(network projects storage clustering clustering_groups clustering_join certificate_update)

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-preseed-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:gen_tcp, :ssl], mode <- [:create, :update, :mixed, :empty] do
    test "#{transport} #{mode} preseed preserves native bodies, ETags, selection and dependency order",
         %{root: root} do
      transport = unquote(transport)
      config = config(unquote(mode))
      {fixture, client, endpoint, identity} = fixture(root, transport)
      expected = oracle(root, endpoint, identity, config)
      refute expected["error"]
      native = HTTPFixture.requests(fixture)
      count = length(native)
      assert {:ok, result} = Preseed.apply(client, config)
      actual = Enum.drop(HTTPFixture.requests(fixture), count)
      native = Enum.drop(native, 1)
      assert comparable(actual) == comparable(native)
      assert length(result.changes) == Enum.count(actual, &(&1.method != "GET"))
      assert Enum.all?(result.changes, &(&1.response.identity == :verified))
      refute inspect(result) =~ "private-certificate"
      refute inspect(result) =~ "private-cluster-token"
      assert client.connection.project == "outer"
      assert client.connection.member == "member +"
      assert_order(actual)
    end
  end

  test "nil cluster-group members preserve membership while an empty list clears it", %{
    root: root
  } do
    {fixture, client, endpoint, identity} = fixture(root, :gen_tcp)

    for members <- [nil, []] do
      config = %{"cluster_groups" => [%{"name" => "group-existing", "members" => members}]}
      refute oracle(root, endpoint, identity, config)["error"]
      native = List.last(HTTPFixture.requests(fixture))
      assert {:ok, _} = Preseed.apply(client, config)
      actual = List.last(HTTPFixture.requests(fixture))
      assert comparable([actual]) == comparable([native])

      assert Jason.decode!(actual.body)["members"] ==
               if(is_nil(members), do: ["retained"], else: [])
    end
  end

  test "pool and volume type conflicts stop without a mutation and retain native data", %{
    root: root
  } do
    {fixture, client, endpoint, identity} = fixture(root, :gen_tcp)

    for config <- [
          %{"storage_pools" => [%{"name" => "pool-existing", "driver" => "zfs"}]},
          %{
            "storage_volumes" => [
              %{"name" => "volume-existing", "Pool" => "local", "type" => "block"}
            ]
          }
        ] do
      assert oracle(root, endpoint, identity, config)["error"] =~ "instead of"
      count = length(HTTPFixture.requests(fixture))

      assert {:error, %Error{kind: :preseed_conflict, response: %{failure: response}}} =
               Preseed.apply(client, config)

      assert response.metadata.data["config"]["retained"] == "old"
      refute Enum.any?(Enum.drop(HTTPFixture.requests(fixture), count), &(&1.method != "GET"))
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "#{transport} native mutation rejection retains completed changes and stops without replay",
         %{root: root} do
      {fixture, client, endpoint, identity} =
        fixture(root, unquote(transport), fn request ->
          if request.method == "POST" and URI.parse(request.target).path == "/1.0/profiles",
            do: %{
              status: 409,
              body: %{type: "error", error_code: 777, error: "native private conflict"}
            },
            else: handler(request)
        end)

      config = %{
        "storage_pools" => [%{"name" => "pool-new", "driver" => "dir"}],
        "profiles" => [%{"name" => "profile-new"}],
        "certificates" => [%{"name" => "never"}]
      }

      assert oracle(root, endpoint, identity, config)["error"] =~ "native private conflict"
      count = length(HTTPFixture.requests(fixture))

      assert {:error, %Error{kind: :native, error_code: 777, http_status: 409} = error} =
               Preseed.apply(client, config)

      assert [%{method: "CreateStoragePool"}] = error.response.completed.changes
      assert error.response.failure.identity == :verified
      assert error.response.failure.raw["error"] == "native private conflict"
      actual = Enum.drop(HTTPFixture.requests(fixture), count)
      assert Enum.count(actual, &(&1.method == "POST")) == 2
      refute Enum.any?(actual, &(URI.parse(&1.target).path == "/1.0/certificates"))
      refute inspect(error) =~ "private conflict"
    end
  end

  test "lost mutation response is uncertain, preserves earlier mutations and is never retried", %{
    root: root
  } do
    {fixture, client, _, _} =
      fixture(root, :gen_tcp, fn request ->
        if request.method == "POST" and URI.parse(request.target).path == "/1.0/profiles",
          do: %{raw: ""},
          else: handler(request)
      end)

    config = %{
      "storage_pools" => [%{"name" => "pool-new", "driver" => "dir"}],
      "profiles" => [%{"name" => "profile-new"}]
    }

    assert {:error, %Error{kind: :uncertain} = error} = Preseed.apply(client, config)
    assert [%{method: "CreateStoragePool"}] = error.response.completed.changes
    assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 2
  end

  for status <- [103, 400] do
    test "accepted cluster operation #{status} retains native identity and journal on wait failure",
         %{root: root} do
      status = unquote(status)

      {fixture, client, _, _} =
        fixture(root, :gen_tcp, fn request ->
          if String.starts_with?(URI.parse(request.target).path, "/1.0/operations/"),
            do: sync(operation(status)),
            else: handler(request)
        end)

      config = %{
        "cluster" => %{"enabled" => true, "server_name" => "fixture"},
        "cluster_groups" => [%{"name" => "never"}]
      }

      assert {:error, %Error{operation: "/1.0/operations/preseed"} = error} =
               Preseed.apply(client, config, timeout: 150)

      assert error.kind in [:deadline, :operation_failed]
      assert [%{method: "UpdateCluster", response: accepted}] = error.response.completed.changes
      assert accepted.operation == error.operation
      assert accepted.type == "async"
      requests = HTTPFixture.requests(fixture)
      assert Enum.count(requests, &(&1.method == "PUT")) == 1
      refute Enum.any?(requests, &(&1.method in ["POST", "DELETE"]))
    end
  end

  test "the total deadline bounds a multi-step sequence and does not reset between requests", %{
    root: root
  } do
    {fixture, client, _, _} =
      fixture(root, :gen_tcp, fn request ->
        Process.sleep(60)
        handler(request)
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{} = error} =
             Preseed.apply(
               client,
               %{
                 "storage_pools" => [
                   %{"name" => "one", "driver" => "dir"},
                   %{"name" => "two", "driver" => "dir"}
                 ]
               },
               timeout: 100
             )

    assert error.kind in [:deadline, :uncertain]
    assert System.monotonic_time(:millisecond) - started < 1000
    assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 1
  end

  test "native read-error fallback performs a single create attempt", %{root: root} do
    {fixture, client, endpoint, identity} =
      fixture(root, :gen_tcp, fn request ->
        if request.method == "GET" and
             URI.parse(request.target).path == "/1.0/profiles/profile-new",
           do: %{status: 503, body: %{type: "error", error_code: 503, error: "read failure"}},
           else: handler(request)
      end)

    config = %{"profiles" => [%{"name" => "profile-new"}]}
    refute oracle(root, endpoint, identity, config)["error"]
    count = length(HTTPFixture.requests(fixture))
    assert {:ok, _} = Preseed.apply(client, config)
    assert [%{method: "GET"}, %{method: "POST"}] = Enum.drop(HTTPFixture.requests(fixture), count)
  end

  test "an already enabled cluster is inspected without configuration replay", %{root: root} do
    {fixture, client, endpoint, identity} =
      fixture(root, :gen_tcp, fn request ->
        if request.method == "GET" and URI.parse(request.target).path == "/1.0/cluster",
          do: sync(%{enabled: true, server_name: "existing"}),
          else: handler(request)
      end)

    config = %{"cluster" => %{"enabled" => true, "server_name" => "replacement"}}
    refute oracle(root, endpoint, identity, config)["error"]
    count = length(HTTPFixture.requests(fixture))
    assert {:ok, %Preseed{changes: []}} = Preseed.apply(client, config)
    assert [%{method: "GET"}] = Enum.drop(HTTPFixture.requests(fixture), count)
  end

  test "unsupported capabilities stop locally and preserve preceding successful mutations", %{
    root: root
  } do
    {fixture, client, _, _} = fixture(root, :gen_tcp)
    client = %{client | server: %{client.server | api_extensions: []}}

    assert {:error, %Error{kind: :unsupported_extension, extension: "network"} = error} =
             Preseed.apply(client, %{
               "config" => %{"changed" => "server"},
               "networks" => [%{"name" => "network-new"}]
             })

    assert [%{method: "UpdateServer"}] = error.response.completed.changes
    assert [%{method: "GET"}, %{method: "PUT"}] = HTTPFixture.requests(fixture)
  end

  test "typed JSON defaults, description overrides and new device properties match native updates",
       %{root: root} do
    {fixture, client, endpoint, identity} = fixture(root, :gen_tcp)

    config = %{
      "ignored_native_field" => "ignored",
      "profiles" => [
        %{
          "name" => "profile-existing",
          "project" => "tenant",
          "description" => "override",
          "config" => %{"numeric" => 1.5, "null" => nil},
          "devices" => %{
            "root" => %{"pool" => "new"},
            "eth0" => %{"type" => "nic", "network" => "br0"}
          }
        }
      ]
    }

    refute oracle(root, endpoint, identity, config)["error"]
    native = List.last(HTTPFixture.requests(fixture))
    assert {:ok, _} = Preseed.apply(client, config)
    actual = List.last(HTTPFixture.requests(fixture))
    assert comparable([actual]) == comparable([native])
    body = Jason.decode!(actual.body)
    assert body["description"] == "override"
    assert body["config"] == %{"retained" => "old", "numeric" => "1.5", "null" => ""}
    assert body["devices"]["root"]["type"] == "disk"
    assert body["devices"]["root"]["pool"] == "new"
  end

  test "invalid models, options, record counts and host readiness fail before any I/O", %{
    root: root
  } do
    {fixture, client, _, _} = fixture(root, :gen_tcp)

    for config <- [
          [],
          %{"profiles" => "bad"},
          %{"profiles" => [%{"config" => %{"bad" => []}}]},
          %{"networks" => [%{"Project" => "one", "project" => "two"}]},
          %{"profiles" => List.duplicate(%{"name" => "x"}, 129)},
          %{"profiles" => [%{"Project" => String.duplicate("x", 1025)}]}
        ] do
      assert {:error, %Error{kind: :invalid_preseed}} = Preseed.apply(client, config)
    end

    for opts <- [[timeout: 0], [timeout: 1, timeout: 2], [unknown: true], %{}] do
      assert {:error, %Error{kind: :invalid_preseed_options}} = Preseed.apply(client, %{}, opts)
    end

    client = %{client | context: %{client.context | ready?: fn -> false end}}

    assert {:error, %Error{kind: :host_not_ready}} =
             Preseed.apply(client, %{"config" => %{"x" => "y"}})

    assert HTTPFixture.requests(fixture) == []
  end

  test "over-budget existing configuration returns its native response without a mutation", %{
    root: root
  } do
    padding = String.duplicate("x", 1_048_577)

    {fixture, client, _, _} =
      fixture(root, :gen_tcp, fn request ->
        if URI.parse(request.target).path == "/1.0",
          do: sync(%{config: %{"padding" => padding}}),
          else: handler(request)
      end)

    assert {:error, %Error{kind: :invalid_native_config} = error} =
             Preseed.apply(client, %{"config" => %{"changed" => "value"}})

    assert error.response.completed.changes == []
    assert error.response.failure.identity == :verified
    assert error.response.failure.metadata["config"]["padding"] == padding
    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  test "bounded result exhaustion retains the most recent accepted response without replay", %{
    root: root
  } do
    {fixture, client, _, _} = fixture(root, :gen_tcp)
    client = %{client | connection: %{client.connection | max_response_bytes: 300}}

    assert {:error, %Error{kind: :preseed_result_limit} = error} =
             Preseed.apply(
               client,
               %{"storage_pools" => [%{"name" => "new", "driver" => "dir"}]}
             )

    assert error.response.failure.type == "sync"
    assert error.response.failure.identity == :verified
    assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 1
  end

  defp comparable(requests) do
    requests
    |> Enum.reject(&String.starts_with?(URI.parse(&1.target).path, "/1.0/operations/"))
    |> Enum.map(&WireComparison.request/1)
  end

  defp assert_order(requests) do
    targets = Enum.map(requests, &URI.parse(&1.target).path)

    if Enum.any?(targets, &(&1 == "/1.0/projects")) do
      network = Enum.find_index(targets, &(&1 == "/1.0/networks/network-default"))
      project = Enum.find_index(targets, &(&1 == "/1.0/projects"))
      tenant = Enum.find_index(targets, &(&1 == "/1.0/networks/network-tenant"))
      assert network < project
      assert project < tenant
    end
  end

  defp config(:empty), do: %{}

  defp config(mode) do
    names =
      case mode do
        :create -> ["new"]
        :update -> ["existing"]
        :mixed -> ["new", "existing"]
      end

    %{
      "config" => %{"changed" => true},
      "storage_pools" =>
        Enum.map(
          names,
          &%{"name" => "pool-#{&1}", "driver" => "dir", "config" => %{"changed" => 7}}
        ),
      "networks" => [
        %{"name" => "network-default", "type" => "bridge"},
        %{"name" => "network-tenant", "Project" => "tenant", "type" => "bridge"}
      ],
      "projects" =>
        Enum.map(names, &%{"name" => "project-#{&1}", "config" => %{"changed" => false}}),
      "storage_volumes" =>
        Enum.map(
          names,
          &%{
            "name" => "volume-#{&1}",
            "Pool" => "local",
            "Project" => "tenant",
            "config" => %{"changed" => "v"}
          }
        ),
      "profiles" =>
        Enum.map(
          names,
          &%{
            "name" => "profile-#{&1}",
            "Project" => "tenant",
            "devices" => %{"root" => %{"pool" => "new-pool"}},
            "config" => %{"changed" => "p"}
          }
        ),
      "certificates" => [
        %{"name" => "cert", "type" => "client", "certificate" => "private-certificate"}
      ],
      "cluster" => %{
        "enabled" => true,
        "server_name" => "fixture",
        "cluster_token" => "private-cluster-token"
      },
      "cluster_groups" => Enum.map(names, &%{"name" => "group-#{&1}"})
    }
  end

  defp fixture(root, transport, handler \\ &handler/1) do
    identity = if transport == :ssl, do: TLSIdentity.generate(root, "id", "localhost"), else: nil

    opts =
      if identity,
        do: [certfile: identity.certfile, keyfile: identity.keyfile],
        else: [path: Path.join(root, "socket-#{System.unique_integer([:positive])}")]

    fixture =
      start_supervised!({HTTPFixture, [transport: transport, handler: handler] ++ opts},
        id: make_ref()
      )

    endpoint = HTTPFixture.endpoint(fixture)

    connection =
      if identity,
        do:
          Connection.https!(endpoint.url,
            owner: :fixture,
            project: "outer",
            member: "member +",
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          ),
        else:
          Connection.unix!(endpoint.socket, owner: :fixture, project: "outer", member: "member +")

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Opsmaru.Incus.Server{api_extensions: @extensions}
    }

    {fixture, client, endpoint, identity}
  end

  defp oracle(root, endpoint, identity, config) do
    input =
      Map.merge(endpoint, %{
        action: "ApplyServerPreseed",
        args: [config],
        project: "outer",
        target: "member +"
      })

    input =
      if identity,
        do:
          Map.merge(input, %{
            tls_ca: File.read!(identity.cafile),
            client_cert: File.read!(identity.certfile),
            client_key: File.read!(identity.keyfile)
          }),
        else: input

    path = Path.join(root, "input.json")
    File.write!(path, Jason.encode!(input))
    {out, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end

  defp handler(request) do
    path = URI.parse(request.target).path

    cond do
      request.method == "PUT" and path == "/1.0/cluster" ->
        %{
          status: 202,
          body: %{type: "async", operation: "/1.0/operations/preseed", metadata: operation(103)}
        }

      request.method != "GET" ->
        sync(%{})

      path == "/1.0" ->
        sync(%{
          api_version: "1.0",
          auth: "trusted",
          api_extensions: @extensions,
          config: %{"retained" => "old"},
          environment: %{server: "incus"}
        })

      path == "/1.0/storage-pools" ->
        sync(["/1.0/storage-pools/pool-existing"])

      path == "/1.0/projects" ->
        sync(["/1.0/projects/project-existing"])

      path == "/1.0/cluster" ->
        sync(%{"enabled" => false, "server_name" => "", "member_config" => nil})

      String.starts_with?(path, "/1.0/operations/") ->
        sync(operation(200))

      String.ends_with?(path, "existing") ->
        sync(existing(path))

      true ->
        %{status: 404, body: %{type: "error", error_code: 404, error: "not found"}}
    end
  end

  defp existing(path) do
    data = %{
      "name" => List.last(String.split(path, "/")),
      "config" => %{"retained" => "old"},
      "description" => "old description"
    }

    cond do
      String.contains?(path, "/profiles/") ->
        Map.put(data, "devices", %{
          "root" => %{"type" => "disk", "path" => "/", "pool" => "old-pool"}
        })

      String.contains?(path, "/volumes/") ->
        Map.put(data, "type", "custom")

      String.contains?(path, "/storage-pools/") ->
        Map.put(data, "driver", "dir")

      String.contains?(path, "/groups/") ->
        Map.put(data, "members", ["retained"])

      true ->
        data
    end
  end

  defp operation(status),
    do: %{
      id: "preseed",
      class: "task",
      status: "fixture",
      status_code: status,
      metadata: %{},
      may_cancel: false,
      err: if(status == 400, do: "native failure", else: "")
    }

  defp sync(metadata),
    do: %{
      status: 200,
      headers: [{"etag", "\"preseed-etag\""}],
      body: %{type: "sync", metadata: metadata}
    }
end
