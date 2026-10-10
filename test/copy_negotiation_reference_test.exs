defmodule Opsmaru.Incus.CopyNegotiationReferenceTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Copy, Error, ImageInstances, Operation, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  @driver Path.expand("../../.integration/copy-negotiation-driver", __DIR__)
  @extensions ~w(storage_api_local_volume_handling storage_api_remote_volume_handling storage_api_project storage_volume_project_move storage_api_volume_snapshots custom_volume_refresh custom_volume_refresh_exclude_older_snapshots container_push container_push_target container_only_migration container_incremental_copy virtual-machines container_snapshot_stateful_migration dependent cluster_migration_inconsistent_copy instance_allow_inconsistent_copy)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./copynegotiation"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-copy-neg-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "native volume move preserves destination pool/project, target member and accepted identity",
       %{root: root} do
    {client, fixture, endpoint} = fixture(root, "move", :unix)
    volume = %{"name" => "source", "type" => "custom", "content_type" => "block"}

    for project <- [nil, "destination"] do
      options = if project, do: %{Name: "renamed", Project: project}, else: %{Name: "renamed"}

      result =
        reference(%{
          action: "move",
          target: endpoint,
          pool: "new-pool",
          source_pool: "old-pool",
          body: volume,
          options: options
        })

      assert result["accepted"] and result["completed"], inspect(result)
      expected = posts(fixture) |> List.last()
      opts = if project, do: [name: "renamed", project: project], else: [name: "renamed"]
      assert {:ok, move} = Copy.move_volume(client, "new-pool", "old-pool", volume, opts)
      actual = posts(fixture) |> List.last()
      assert actual.target == expected.target
      assert subset?(Jason.decode!(actual.body), Jason.decode!(expected.body))
      assert move.mode == :local
      assert move.target.url == "/1.0/operations/move"
      refute Operation.completed?(move.target)
      assert Jason.decode!(actual.body)["pool"] == "new-pool"
      assert URI.decode_query(URI.parse(actual.target).query)["target"] == "member"
    end
  end

  test "volume move guards reject before mutation and lost response stays uncertain without replay",
       %{root: root} do
    {client, fixture, _} = fixture(root, "move", :unix)
    model = %{"name" => "volume", "type" => "custom"}

    no_project = %{
      client
      | server: %{client.server | api_extensions: ["storage_api_local_volume_handling"]}
    }

    assert {:error, %Error{kind: :unsupported_extension}} =
             Copy.move_volume(no_project, "p", "s", model, name: "v", project: "other")

    for opts <- [[], [name: ""], [name: "v", mode: :push], %{}] do
      assert {:error, %Error{kind: :invalid_move_options}} =
               Copy.move_volume(client, "p", "s", model, opts)
    end

    assert posts(fixture) == []
    {lost, lost_fixture, _} = fixture(root, "lost", :unix, :disconnect)

    log =
      capture_log(fn ->
        assert {:error, %Error{kind: :uncertain}} =
                 Copy.move_volume(lost, "p", "s", model, name: "v")
      end)

    refute log =~ "native-secret"
    assert length(posts(lost_fixture)) == 1
    refute Enum.any?(HTTPFixture.requests(lost_fixture), &(&1.method == "DELETE"))
  end

  for kind <- [:instance, :snapshot, :volume], mode <- [:pull, :push] do
    test "#{kind} #{mode}: official native copy negotiation matches approved descriptors and writable fields",
         %{root: root} do
      compare_copy(root, unquote(kind), unquote(mode))
    end
  end

  defp compare_copy(root, kind, mode) do
    barrier = start_supervised!({Agent, fn -> MapSet.new() end})
    {source, source_fixture, source_endpoint} = fixture(root, "source", :https, :accept, barrier)
    {target, target_fixture, target_endpoint} = fixture(root, "target", :https, :accept, barrier)
    model = model(kind)
    origin = if mode == :push, do: target_endpoint.url, else: source_endpoint.url
    options = %{Name: "copied", Mode: Atom.to_string(mode), Live: true}
    options = if kind == :volume, do: Map.delete(options, :Live), else: options

    result =
      reference(%{
        action: kind,
        source: source_endpoint,
        target: target_endpoint,
        body: model,
        options: options,
        pool: "new-pool",
        source_pool: "old-pool",
        parent: "parent"
      })

    assert result["accepted"] and result["completed"], inspect(result)
    expected_source = posts(source_fixture) |> List.last()
    expected_target = posts(target_fixture) |> List.last()

    log =
      capture_log(fn ->
        opts = [name: "copied", mode: mode, approved_origin: origin]
        opts = if kind == :volume, do: opts, else: Keyword.put(opts, :live, true)

        result =
          case kind do
            :instance -> Copy.instance(target, source, model, opts)
            :snapshot -> Copy.snapshot(target, source, "parent", model, opts)
            :volume -> Copy.volume(target, source, "new-pool", "old-pool", model, opts)
          end

        assert {:ok, migration} = result
        assert migration.source.url == "/1.0/operations/source"
        assert migration.target.url == "/1.0/operations/target"
        refute Operation.completed?(migration.source)
        refute Operation.completed?(migration.target)
        refute inspect(migration) =~ "native-secret"
      end)

    refute log =~ "native-secret"

    for {fixture, expected} <- [
          {source_fixture, expected_source},
          {target_fixture, expected_target}
        ] do
      actual = posts(fixture) |> List.last()
      assert actual.method == expected.method
      assert actual.target == expected.target

      assert subset?(Jason.decode!(actual.body), Jason.decode!(expected.body)),
             inspect({Jason.decode!(actual.body), Jason.decode!(expected.body)})

      # Only the official call and one Opsmaru mutation. No cancellation/replay.
      assert length(posts(fixture)) == 2
      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
    end
  end

  test "source member fallback uses server identity for native internal cluster volume copy", %{
    root: root
  } do
    {client, fixture, endpoint} = fixture(root, "local", :unix)

    client = %{
      client
      | connection: %{client.connection | member: nil},
        server: %{
          client.server
          | api_extensions: ["cluster_internal_custom_volume_copy" | @extensions]
        }
    }

    # Pinned GetConnectionInfo defaults Target to environment.server_name.
    source = client

    result =
      reference(%{
        action: "volume",
        source: %{endpoint | member: ""},
        target: %{endpoint | member: ""},
        pool: "p",
        source_pool: "s",
        body: model(:volume),
        options: %{Name: "copy"}
      })

    refute result["error"], inspect(result)
    expected = posts(fixture) |> List.last()
    assert {:ok, _} = Copy.volume(client, source, "p", "s", model(:volume), name: "copy")
    actual = posts(fixture) |> List.last()
    assert Jason.decode!(expected.body)["source"]["location"] == "native-member"
    assert Jason.decode!(actual.body)["source"]["location"] == "native-member"
  end

  for action <- [:create, :rebuild], location <- [:local, :public, :private] do
    test "image #{action} #{location}: unchanged native preparation matches the explicit source",
         %{root: root} do
      compare_image(root, unquote(action), unquote(location))
    end
  end

  defp compare_image(root, action, location) do
    {target, target_fixture, target_endpoint} =
      fixture(root, "target", if(location == :local, do: :unix, else: :https))

    {source, source_fixture, source_endpoint} =
      if location == :local,
        do: {target, target_fixture, target_endpoint},
        else: fixture(root, "source", :https)

    image = %{"fingerprint" => String.duplicate("a", 64), "public" => location != :private}
    body = %{"source" => %{"alias" => "latest"}}

    body =
      if action == :create,
        do: Map.merge(body, %{"name" => "from-image", "profiles" => ["default"]}),
        else: body

    expected =
      reference(%{
        action: if(action == :create, do: "create-image", else: "rebuild-image"),
        target: target_endpoint,
        source: source_endpoint,
        image: image,
        body: body,
        parent: "existing"
      })

    refute expected["error"], inspect(expected)
    native = posts(target_fixture) |> List.last()
    before_source = length(posts(source_fixture))
    opts = if location == :local, do: [], else: [approved_origin: source_endpoint.url]

    call = fn ->
      if action == :create,
        do: ImageInstances.create(target, source, image, body, opts),
        else: ImageInstances.rebuild(target, source, image, "existing", body, opts)
    end

    log =
      capture_log(fn ->
        assert {:ok, operation} = call.()
        assert operation.url == "/1.0/operations/target"
        refute Operation.completed?(operation)
        refute inspect(operation) =~ "native-secret"
      end)

    refute log =~ "native-secret"
    actual = posts(target_fixture) |> List.last()
    assert actual.target == native.target

    assert subset?(Jason.decode!(actual.body), Jason.decode!(native.body)),
           inspect({Jason.decode!(actual.body), Jason.decode!(native.body)})

    fields = Jason.decode!(actual.body)["source"]

    if location == :local do
      assert fields["fingerprint"] == image["fingerprint"]
      assert Map.get(fields, "alias", "") == ""
    else
      assert fields["server"] == source_endpoint.url
      assert fields["protocol"] == "incus"
      assert fields["certificate"] == source_endpoint.certificate

      if location == :private do
        assert fields["secret"] == "native-secret"
        assert fields["fingerprint"] == image["fingerprint"]
        assert length(posts(source_fixture)) == before_source + 1
      else
        assert fields["alias"] == "latest"
        assert Map.get(fields, "fingerprint", "") == ""
        assert length(posts(source_fixture)) == before_source
      end
    end
  end

  test "private image preparation approves origin before token creation and retains its identity on target loss",
       %{root: root} do
    {source, source_fixture, endpoint} = fixture(root, "source", :https)
    {target, lost_fixture, _} = fixture(root, "lost", :unix, :disconnect)
    image = %{"fingerprint" => String.duplicate("a", 64), "public" => false}
    body = %{"name" => "created"}

    assert {:error, %Error{kind: :unapproved_image_origin}} =
             ImageInstances.create(target, source, image, body,
               approved_origin: "https://advertised.example"
             )

    assert posts(source_fixture) == []
    assert posts(lost_fixture) == []

    assert {:error, %Error{kind: :uncertain, response: %{source: token}} = error} =
             ImageInstances.create(target, source, image, body, approved_origin: endpoint.url)

    assert token.operation == "/1.0/operations/source"
    assert length(posts(source_fixture)) == 1
    assert length(posts(lost_fixture)) == 1
    refute inspect(error) =~ "native-secret"
    refute Enum.any?(HTTPFixture.requests(lost_fixture), &(&1.method == "DELETE"))
    no_rebuild = %{target | server: %Server{api_extensions: []}}

    assert {:error, %Error{kind: :unsupported_extension}} =
             ImageInstances.rebuild(no_rebuild, source, image, "old", %{},
               approved_origin: endpoint.url
             )

    assert length(posts(source_fixture)) == 1
  end

  test "local snapshot copy does not send the remote-only parent instance type", %{root: root} do
    {client, fixture, endpoint} = fixture(root, "local", :unix)

    result =
      reference(%{
        action: "snapshot",
        source: endpoint,
        target: endpoint,
        parent: "parent",
        body: model(:snapshot),
        options: %{Name: "copied", Live: true}
      })

    refute result["error"], inspect(result)
    expected = posts(fixture) |> List.last()

    assert {:ok, copy} =
             Copy.snapshot(client, client, "parent", model(:snapshot), name: "copied", live: true)

    assert copy.mode == :local
    actual = posts(fixture) |> List.last()
    assert subset?(Jason.decode!(actual.body), Jason.decode!(expected.body))
    refute Map.has_key?(Jason.decode!(actual.body), "type")
    assert Jason.decode!(actual.body)["stateful"] == true
    assert Jason.decode!(actual.body)["source"]["source"] == "parent/snapshot"
  end

  defp model(:instance),
    do: %{
      "name" => "source",
      "type" => "container",
      "status_code" => 103,
      "architecture" => "aarch64",
      "config" => %{"volatile.base_image" => "image"},
      "devices" => %{"root" => %{"type" => "disk", "pool" => "p"}},
      "profiles" => ["default"],
      "ephemeral" => true
    }

  defp model(:snapshot),
    do: %{
      "name" => "parent/snapshot",
      "stateful" => true,
      "config" => %{"volatile.base_image" => "image"},
      "devices" => %{},
      "profiles" => ["default"],
      "ephemeral" => true
    }

  defp model(:volume),
    do: %{
      "name" => "volume",
      "type" => "custom",
      "location" => "none",
      "config" => %{"size" => "10GiB"},
      "description" => "native",
      "content_type" => "block"
    }

  defp fixture(root, name, transport, outcome \\ :accept, barrier \\ nil) do
    identity =
      if transport == :https, do: TLSIdentity.generate(root, name, "localhost"), else: nil

    certificate = if identity, do: File.read!(identity.certfile), else: ""
    extensions = ["instances_rebuild", "cluster_internal_custom_volume_copy" | @extensions]

    opts =
      if identity,
        do: [transport: :ssl, certfile: identity.certfile, keyfile: identity.keyfile],
        else: [transport: :gen_tcp, path: Path.join(root, name <> ".sock")]

    fixture =
      start_supervised!(
        {HTTPFixture,
         opts ++
           [
             handler: fn req ->
               cond do
                 URI.parse(req.target).path == "/1.0" ->
                   %{
                     status: 200,
                     body: %{
                       type: "sync",
                       metadata: %{
                         api_version: "1.0",
                         auth: "trusted",
                         api_extensions: extensions,
                         environment: %{
                           server_name: "native-member",
                           server_clustered: false,
                           certificate: certificate
                         }
                       }
                     }
                   }

                 req.method == "POST" and outcome == :disconnect ->
                   %{raw: ""}

                 req.method == "POST" ->
                   if barrier, do: Agent.update(barrier, &MapSet.put(&1, name))

                   %{
                     status: 202,
                     body: %{
                       type: "async",
                       operation: "/1.0/operations/" <> name,
                       metadata: %{
                         id: name,
                         status_code: 103,
                         metadata:
                           if(String.contains?(req.target, "/images/"),
                             do: %{secret: "native-secret"},
                             else: %{control: "native-secret", fs: "data-secret"}
                           )
                       }
                     }
                   }

                 String.contains?(req.target, "/operations/") ->
                   if barrier,
                     do: await_posts(barrier, System.monotonic_time(:millisecond) + 2_000)

                   %{status: 200, body: %{type: "sync", metadata: %{id: name, status_code: 200}}}

                 true ->
                   %{
                     status: 200,
                     body: %{
                       type: "sync",
                       metadata: %{name: "parent", type: "virtual-machine", location: ""}
                     }
                   }
               end
             end
           ]},
        id: make_ref()
      )

    endpoint = HTTPFixture.endpoint(fixture)

    connection =
      if identity,
        do:
          Connection.https!(endpoint.url,
            owner: :fixture,
            project: "fixture",
            member: "member",
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          ),
        else:
          Connection.unix!(endpoint.socket, owner: :fixture, project: "fixture", member: "member")

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{
        api_extensions: extensions,
        environment: %{
          "server_name" => "native-member",
          "server_clustered" => false,
          "certificate" => certificate
        }
      }
    }

    {client, fixture,
     Map.merge(endpoint, %{certificate: certificate, project: "fixture", member: "member"})}
  end

  defp await_posts(barrier, deadline) do
    if Agent.get(barrier, &MapSet.size/1) < 2 do
      assert System.monotonic_time(:millisecond) < deadline,
             "native copy negotiation did not issue both requests"

      Process.sleep(5)
      await_posts(barrier, deadline)
    end
  end

  defp posts(fixture), do: Enum.filter(HTTPFixture.requests(fixture), &(&1.method == "POST"))

  defp reference(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, out) do
    receive do
      {^port, {:data, bytes}} -> collect(port, out <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(out)
      {^port, {:exit_status, status}} -> flunk("reference failed #{status}: #{out}")
    after
      10_000 ->
        Port.close(port)
        flunk("reference deadline")
    end
  end

  defp subset?(actual, expected) when is_map(actual) and is_map(expected),
    do: Enum.all?(actual, fn {k, v} -> Map.has_key?(expected, k) and subset?(v, expected[k]) end)

  defp subset?(actual, expected), do: actual == expected
end
