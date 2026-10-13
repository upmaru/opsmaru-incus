defmodule Opsmaru.Incus.CopyNegotiationReferenceTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Copy, Error, ImageInstances, Migration, Operation, Server}
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

  test "remote operation wait matches the pinned client for target success and failure", %{
    root: root
  } do
    volume = %{"name" => "source", "type" => "custom", "content_type" => "block"}

    for {name, outcome} <- [{"waitok", :accept}, {"waitfail", :fail}] do
      {client, _fixture, endpoint} = fixture(root, name, :unix, outcome)

      native =
        reference(%{
          action: "move",
          target: endpoint,
          pool: "new-pool",
          source_pool: "old-pool",
          body: volume,
          options: %{Name: "renamed"}
        })

      assert native["accepted"], inspect(native)

      assert {:ok, move} =
               Copy.move_volume(client, "new-pool", "old-pool", volume, name: "renamed")

      case outcome do
        :accept ->
          assert native["completed"]
          assert {:ok, %Migration{target: target}} = Migration.wait_target(move, timeout: 1_000)
          assert Operation.successful?(target)

        :fail ->
          assert native["error"] == "boom"

          assert {:error, %Error{response: %{error: %Error{kind: :operation_failed} = error}}} =
                   Migration.wait_target(move, timeout: 1_000)

          assert Operation.data(%{move.target | response: error.response})["err"] ==
                   native["error"]
      end
    end
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

  for kind <- [:instance, :snapshot, :volume], locality <- [:local, :remote] do
    @tag timeout: 180_000
    test "#{kind} #{locality} all boolean combinations and pull/push options match native requests",
         %{
           root: root
         } do
      compare_options(root, unquote(kind), unquote(locality))
    end
  end

  defp compare_options(root, kind, locality) do
    barrier =
      if locality == :remote, do: start_supervised!({Agent, fn -> MapSet.new() end}), else: nil

    {source, source_fixture, source_endpoint} =
      fixture(root, "option-source", :https, :accept, barrier)

    {target, target_fixture, target_endpoint} =
      if locality == :local,
        do: {source, source_fixture, source_endpoint},
        else: fixture(root, "option-target", :https, :accept, barrier)

    cases =
      for flags <- boolean_options(kind),
          mode <- [:pull, :push],
          inactive? <- [false, true],
          do: {Keyword.put(flags, :mode, mode), inactive?}

    for {flags, inactive?} <- [{[], false}, {[name: ""], false} | cases] do
      if barrier, do: Agent.update(barrier, fn _ -> MapSet.new() end)
      data = option_model(kind, inactive?)

      native_keys = %{
        name: :Name,
        live: :Live,
        instance_only: :InstanceOnly,
        refresh: :Refresh,
        refresh_exclude_older: :RefreshExcludeOlder,
        allow_inconsistent: :AllowInconsistent,
        volume_only: :VolumeOnly,
        mode: :Mode
      }

      options =
        Map.new(flags, fn {key, value} ->
          {native_keys[key], if(key == :mode, do: Atom.to_string(value), else: value)}
        end)

      result =
        reference(%{
          action: kind,
          source: source_endpoint,
          target: target_endpoint,
          body: data,
          options: options,
          pool: "new-pool",
          source_pool: "old-pool",
          parent: "parent"
        })

      refute result["error"], inspect(result)
      expected_target = List.last(posts(target_fixture))
      expected_source = if locality == :remote, do: List.last(posts(source_fixture))
      target_count = length(posts(target_fixture))
      source_count = length(posts(source_fixture))

      origin = if flags[:mode] == :push, do: target_endpoint.url, else: source_endpoint.url
      opts = if locality == :remote, do: Keyword.put(flags, :approved_origin, origin), else: flags

      outcome = option_copy(kind, target, source, data, opts)

      assert {:ok, migration} = outcome

      assert Jason.decode!(List.last(posts(target_fixture)).body) ==
               Jason.decode!(expected_target.body)

      assert List.last(posts(target_fixture)).target == expected_target.target

      assert length(posts(target_fixture)) == target_count + 1

      if locality == :remote do
        assert Jason.decode!(List.last(posts(source_fixture)).body) ==
                 Jason.decode!(expected_source.body)

        assert List.last(posts(source_fixture)).target == expected_source.target

        assert length(posts(source_fixture)) == source_count + 1
      end

      refute Operation.completed?(migration.target)
      refute Enum.any?(HTTPFixture.requests(target_fixture), &(&1.method == "DELETE"))
    end
  end

  defp boolean_options(kind) do
    Enum.reduce(enabled_options(kind), [[]], fn {key, _}, combinations ->
      for options <- combinations, value <- [false, true], do: [{key, value} | options]
    end)
  end

  for kind <- [:instance, :snapshot, :volume] do
    test "#{kind} cluster placement, internal copy and project selection match native negotiation",
         %{root: root} do
      for {clustered, internal, member, location} <- [
            {false, false, "destination", "source"},
            {true, false, "source", "source"},
            {true, false, "destination", "source"},
            {true, true, "destination", "source"},
            {true, false, "", "none"},
            {true, true, "", "source"}
          ] do
        topology = [clustered: clustered, internal: internal, location: location]
        name = "cluster-#{System.unique_integer([:positive])}"

        local =
          internal or member == location or
            (unquote(kind) == :volume and member == "" and location == "none") or
            (unquote(kind) != :volume and not clustered)

        barrier =
          if local,
            do: nil,
            else: start_supervised!({Agent, fn -> MapSet.new() end}, id: make_ref())

        {base, backend, endpoint} = fixture(root, name, :https, :accept, barrier, topology)
        source = %{base | connection: %{base.connection | member: nil, project: "source-project"}}

        target = %{
          base
          | connection: %{
              base.connection
              | member: nil_if_empty(member),
                project: "target-project"
            }
        }

        source_endpoint = %{endpoint | member: "", project: "source-project"}
        target_endpoint = %{endpoint | member: member, project: "target-project"}
        data = Map.put(model(unquote(kind)), "location", location)

        for mode <- [:pull, :push] do
          if barrier, do: Agent.update(barrier, fn _ -> MapSet.new() end)
          before = length(posts(backend))

          input = %{
            action: unquote(kind),
            source: source_endpoint,
            target: target_endpoint,
            body: data,
            pool: "new-pool",
            source_pool: "old-pool",
            parent: "parent",
            options: %{Name: "cluster-copy", Mode: Atom.to_string(mode)}
          }

          native = reference(input)
          refute native["error"], inspect(native)
          expected = posts(backend) |> Enum.drop(before) |> Enum.map(&request_value/1)
          before_actual = length(posts(backend))

          assert {:ok, migration} =
                   option_copy(unquote(kind), target, source, data,
                     name: "cluster-copy",
                     mode: mode,
                     approved_origin: endpoint.url
                   )

          actual = posts(backend) |> Enum.drop(before_actual) |> Enum.map(&request_value/1)

          assert length(actual) == length(expected),
                 inspect({clustered, internal, member, location, mode, unquote(kind)})

          for {{method, path, body}, {native_method, native_path, native_body}} <-
                Enum.zip(actual, expected) do
            assert {method, path} == {native_method, native_path}
            assert body == native_body
          end

          assert length(actual) in [1, 2]
          assert migration.mode == :local == (length(actual) == 1)
          assert migration.target.url == "/1.0/operations/" <> name
          refute Operation.completed?(migration.target)
          refute Enum.any?(HTTPFixture.requests(backend), &(&1.method == "DELETE"))
        end
      end
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value
  defp request_value(request), do: {request.method, request.target, Jason.decode!(request.body)}

  defp enabled_options(:instance),
    do: [
      live: true,
      instance_only: true,
      refresh: true,
      refresh_exclude_older: true,
      allow_inconsistent: true
    ]

  defp enabled_options(:snapshot), do: [live: true]

  defp enabled_options(:volume),
    do: [volume_only: true, refresh: true, refresh_exclude_older: true]

  defp option_model(:instance, true), do: Map.put(model(:instance), "status_code", 102)
  defp option_model(:snapshot, true), do: Map.put(model(:snapshot), "stateful", false)
  defp option_model(kind, _), do: model(kind)

  defp option_copy(:instance, target, source, data, opts),
    do: Copy.instance(target, source, data, opts)

  defp option_copy(:snapshot, target, source, data, opts),
    do: Copy.snapshot(target, source, "parent", data, opts)

  defp option_copy(:volume, target, source, data, opts),
    do: Copy.volume(target, source, "new-pool", "old-pool", data, opts)

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

      assert Jason.decode!(actual.body) == Jason.decode!(expected.body),
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

  test "unchanged reference omits implicit source project; Opsmaru retains its bound selection",
       %{root: root} do
    {target, target_fixture, target_endpoint} = fixture(root, "project-target", :https)
    {source, _, source_endpoint} = fixture(root, "project-source", :https)
    image = %{"fingerprint" => String.duplicate("a", 64), "public" => true}
    body = %{"name" => "project-image", "source" => %{"alias" => "latest"}}

    expected =
      reference(%{
        action: "create-image",
        target: target_endpoint,
        source: source_endpoint,
        image: image,
        body: body
      })

    refute expected["error"], inspect(expected)
    native = posts(target_fixture) |> List.last() |> Map.fetch!(:body) |> Jason.decode!()
    refute Map.has_key?(native["source"], "project")

    assert {:ok, operation} =
             ImageInstances.create(target, source, image, body,
               approved_origin: source_endpoint.url
             )

    actual = posts(target_fixture) |> List.last() |> Map.fetch!(:body) |> Jason.decode!()
    assert actual == put_in(native, ["source", "project"], source.connection.project)
    assert operation.url == "/1.0/operations/project-target"
    refute Operation.completed?(operation)
  end

  test "conflicting source project rejects before token creation or target mutation", %{
    root: root
  } do
    {target, target_fixture, _} = fixture(root, "bound-target", :https)
    {source, source_fixture, endpoint} = fixture(root, "bound-source", :https)
    image = %{"fingerprint" => String.duplicate("a", 64), "public" => false}
    body = %{"name" => "wrong", "source" => %{"project" => "another-project"}}

    assert {:error, %Error{kind: :image_project_mismatch}} =
             ImageInstances.create(target, source, image, body, approved_origin: endpoint.url)

    assert posts(source_fixture) == []
    assert posts(target_fixture) == []
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
        # The unchanged 7.0.1 helper does not infer source project; provide its
        # explicit request field. Opsmaru must derive it from the bound source.
        body:
          if(location == :local,
            do: body,
            else: put_in(body, ["source", "project"], source.connection.project)
          ),
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

    assert Jason.decode!(actual.body) == Jason.decode!(native.body),
           inspect({Jason.decode!(actual.body), Jason.decode!(native.body)})

    fields = Jason.decode!(actual.body)["source"]

    if location == :local do
      assert fields["fingerprint"] == image["fingerprint"]
      assert Map.get(fields, "alias", "") == ""
    else
      assert fields["server"] == source_endpoint.url
      assert fields["project"] == source.connection.project
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
    assert Jason.decode!(actual.body) == Jason.decode!(expected.body)
    assert Jason.decode!(actual.body)["type"] == ""
    assert Jason.decode!(actual.body)["stateful"] == true
    assert Jason.decode!(actual.body)["source"]["source"] == "parent/snapshot"
  end

  test "copy retains non-default writable restore and disk-only fields", %{root: root} do
    {client, fixture, endpoint} = fixture(root, "writable", :unix)

    data =
      model(:instance)
      |> Map.merge(%{
        "restore" => "snapshot",
        "disk_only" => true,
        "description" => "native description",
        "stateful" => true
      })

    result =
      reference(%{
        action: "instance",
        source: endpoint,
        target: endpoint,
        body: data,
        options: %{Name: "copied"}
      })

    refute result["error"], inspect(result)
    native = List.last(posts(fixture))
    assert {:ok, migration} = Copy.instance(client, client, data, name: "copied")
    refute Operation.completed?(migration.target)
    actual = List.last(posts(fixture))
    assert Jason.decode!(actual.body) == Jason.decode!(native.body)
    assert Jason.decode!(actual.body)["restore"] == "snapshot"
    assert Jason.decode!(actual.body)["disk_only"]
    assert length(posts(fixture)) == 2
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

  defp fixture(root, name, transport, outcome \\ :accept, barrier \\ nil, topology \\ []) do
    identity =
      if transport == :https, do: TLSIdentity.generate(root, name, "localhost"), else: nil

    certificate = if identity, do: File.read!(identity.certfile), else: ""
    extensions = fixture_extensions(topology)
    clustered = Keyword.get(topology, :clustered, false)

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
                           server_clustered: clustered,
                           certificate: certificate
                         }
                       }
                     }
                   }

                 req.method == "POST" and outcome == :disconnect ->
                   %{raw: ""}

                 req.method == "POST" ->
                   record_post(barrier, {name, req.target})

                   %{
                     status: 202,
                     body: %{
                       type: "async",
                       operation: "/1.0/operations/" <> name,
                       metadata: %{
                         id: name,
                         status_code: 103,
                         metadata: operation_secrets(req.target)
                       }
                     }
                   }

                 String.contains?(req.target, "/operations/") ->
                   if barrier,
                     do: await_posts(barrier, System.monotonic_time(:millisecond) + 2_000)

                   %{status: 200, body: %{type: "sync", metadata: final_operation(name, outcome)}}

                 true ->
                   %{
                     status: 200,
                     body: %{
                       type: "sync",
                       metadata: parent_metadata(topology)
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
          "server_clustered" => clustered,
          "certificate" => certificate
        }
      }
    }

    {client, fixture,
     Map.merge(endpoint, %{certificate: certificate, project: "fixture", member: "member"})}
  end

  defp final_operation(name, :fail),
    do: %{id: name, status_code: 400, status: "Failure", err: "boom"}

  defp final_operation(name, _outcome), do: %{id: name, status_code: 200}

  defp fixture_extensions(topology) do
    extensions = ["instances_rebuild", "container_copy_project" | @extensions]

    if Keyword.get(topology, :internal, true),
      do: ["cluster_internal_copy", "cluster_internal_custom_volume_copy" | extensions],
      else: extensions
  end

  defp parent_metadata(topology),
    do: %{name: "parent", type: "virtual-machine", location: topology[:location] || ""}

  defp record_post(nil, _), do: :ok
  defp record_post(barrier, name), do: Agent.update(barrier, &MapSet.put(&1, name))

  defp operation_secrets(target),
    do:
      if(String.contains?(target, "/images/"),
        do: %{secret: "native-secret"},
        else: %{control: "native-secret", fs: "data-secret"}
      )

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
