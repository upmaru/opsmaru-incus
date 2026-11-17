defmodule Opsmaru.Incus.OperationsNativeTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Operations.{Composite, Evidence, Fragments, Native, Schema}
  alias Opsmaru.TestSupport.{OperationsFixture, OperationsHost, ProfileChecks}

  import OperationsFixture, only: [sync: 1, sync: 2, native_error: 2, accepted: 1]

  @uuid "01234567-89ab-cdef-0123-456789abcdef"
  @document Native.openapi()
  @components @document["components"]["schemas"]
  @operations Map.new(@document["paths"], fn {_, %{"post" => post}} ->
                {post["operationId"], post}
              end)
  @methods "../priv/incus/methods.json"
           |> Path.expand(__DIR__)
           |> File.read!()
           |> Jason.decode!()
           |> Map.fetch!("methods")

  setup do
    root = OperationsFixture.root()
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp start(root, routes \\ fn _ -> :next end, opts \\ []) do
    fixture =
      OperationsFixture.start(
        root,
        Keyword.get(opts, :transport, :gen_tcp),
        routes,
        Keyword.take(opts, [:extensions])
      )

    {fixture, %{binding: {fixture.connection, fixture.context}, test_pid: self()}}
  end

  defp run(name, input, caller, scopes \\ Native.scopes()),
    do: Native.run(name, input, host: OperationsHost, caller: caller, scopes: scopes)

  defp backend(fixture), do: OperationsFixture.backend_requests(fixture)
  defp refute_backend(fixture), do: assert(OperationsFixture.requests(fixture) == [])

  defp schema(name, response),
    do: @operations[name]["responses"][response]["content"]["application/json"]["schema"]

  # A result matches the operation's `200` schema; an error, wrapped as the
  # host returns it, matches `default`.
  defp valid!(name, {:ok, result}) do
    assert :ok = Schema.validate(schema(name, "200"), result, @components)
    result
  end

  defp valid!(name, {:error, error}) do
    assert :ok = Schema.validate(schema(name, "default"), %{"error" => error}, @components)
    error
  end

  describe "the native document" do
    test "names the profile, source and package version and is pure JSON-safe data" do
      assert @document["x-tama-profile"] == "tama-operations/1"
      assert @document["x-tama-source"] == "opsmaru_incus_native"
      assert @document["info"]["version"] == Mix.Project.config()[:version]
      assert @document["info"]["version"] == Composite.openapi()["info"]["version"]
      assert Native.openapi() == @document
      assert @document |> Jason.encode!() |> Jason.decode!() == @document
    end

    test "conforms structurally to tama-operations/1" do
      assert ProfileChecks.issues(@document) == []
    end

    test "is the generated file plus the package version" do
      generated =
        "../priv/incus/native-operations.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      assert Map.delete(@document["info"], "version") == generated["document"]["info"]
      assert Map.delete(@document, "info") == Map.delete(generated["document"], "info")
      assert Native.unavailable() == generated["unavailable"]
    end

    test "exports exactly the verified methods without a recorded exclusion" do
      exported = for {_, operation} <- @operations, do: operation["x-opsmaru-native"]["method"]
      unavailable = Enum.map(Native.unavailable(), & &1["method"])
      all = Enum.map(@methods, & &1["name"])

      assert Enum.sort(exported ++ unavailable) == Enum.sort(all)
      assert length(exported) == 274 and length(unavailable) == 33

      for {id, operation} <- @operations do
        method = operation["x-opsmaru-native"]["method"]
        assert id == "incus_native_" <> Macro.underscore(method) or id =~ ~r/acl|uuid/, id
        assert String.starts_with?(id, "incus_native_")
        assert operation["x-opsmaru-requires"] == [method]
        assert {:ok, _} = Evidence.lookup(method)
        assert hd(operation["tags"]) == "native"
      end

      assert Map.has_key?(@operations, "incus_native_delete_instance")
      assert Map.has_key?(@operations, "incus_native_get_network_acls")
    end

    test "does not share operation IDs with the composite document" do
      composite =
        for {_, %{"post" => post}} <- Composite.openapi()["paths"], do: post["operationId"]

      assert composite -- Map.keys(@operations) == composite
    end

    test "lists unavailable methods by rule, in name order" do
      unavailable = Native.unavailable()
      assert Enum.map(unavailable, & &1["name"]) == Enum.sort(Enum.map(unavailable, & &1["name"]))

      assert Enum.frequencies_by(unavailable, & &1["rule"]) == %{
               "interactive_channel" => 2,
               "binary_transfer" => 8,
               "remote_backend_or_credential" => 23
             }

      for entry <- unavailable do
        assert entry["name"] == "incus_native_" <> Macro.underscore(entry["method"])
        assert is_binary(entry["reason"]) and entry["reason"] != ""
        refute Map.has_key?(@operations, entry["name"])
        assert {:error, %{"kind" => "unknown_operation"}} = run(entry["name"], %{}, %{})
      end
    end

    test "exec is unavailable for an interactive channel and stays a composite operation" do
      refute Map.has_key?(@operations, "incus_native_exec_instance")
      refute Map.has_key?(@operations, "incus_native_console_instance")

      exec = Enum.find(Native.unavailable(), &(&1["method"] == "ExecInstance"))
      assert exec["rule"] == "interactive_channel"
      assert exec["reason"] =~ "interactive channel"
      assert exec["reason"] =~ "incus_instance_exec"
      assert {:ok, _} = Composite.fetch("incus_instance_exec")
    end

    test "uses separate scopes, with admin for certificates, cluster and server writes" do
      assert Native.scopes() ==
               ~w(incus.native.read incus.native.write incus.native.delete incus.native.admin)

      assert Native.scopes() -- Composite.scopes() == Native.scopes()

      for {id, operation} <- @operations do
        native = operation["x-opsmaru-native"]
        assert [scope] = operation["x-tama-scopes"]
        assert scope in Native.scopes(), id

        admin_path? =
          String.starts_with?(native["path"], ["/1.0/certificates", "/1.0/cluster"]) or
            (native["path"] == "/1.0" and native["verb"] in ["PUT", "PATCH"])

        if admin_path?, do: assert(scope == "incus.native.admin", id)
      end

      scope = fn id -> @operations[id]["x-tama-scopes"] end
      assert scope.("incus_native_get_instance") == ["incus.native.read"]
      assert scope.("incus_native_create_instance") == ["incus.native.write"]
      assert scope.("incus_native_patch_instance") == ["incus.native.write"]
      assert scope.("incus_native_delete_instance") == ["incus.native.delete"]
      assert scope.("incus_native_get_certificates") == ["incus.native.admin"]
      assert scope.("incus_native_get_cluster_members") == ["incus.native.admin"]
      assert scope.("incus_native_update_server") == ["incus.native.admin"]
      # Policy override: projects are the isolation boundary.
      assert scope.("incus_native_delete_project") == ["incus.native.admin"]
      assert scope.("incus_native_get_project") == ["incus.native.read"]
    end

    test "every DELETE and PUT is destructive and confirms its target" do
      for {id, operation} <- @operations do
        native = operation["x-opsmaru-native"]
        input = operation["requestBody"]["content"]["application/json"]["schema"]

        if native["verb"] in ["DELETE", "PUT"] do
          assert operation["x-tama-destructive"] == true, id
          assert operation["x-tama-confirmation"]["field"] == "confirm", id
          assert "confirm" in input["required"], id
        end

        assert Map.has_key?(native, "confirm") == operation["x-tama-destructive"], id
      end

      delete = @operations["incus_native_delete_instance"]

      assert delete["x-tama-confirmation"] ==
               %{"field" => "confirm", "description" => "the exact value of `name`"}

      assert @operations["incus_native_update_server"]["x-tama-confirmation"]["description"] ==
               "the literal `server`"

      assert @operations["incus_native_delete_storage_pool_volume_snapshot"]["x-opsmaru-native"][
               "confirm"
             ] == %{"param" => "snapshotName"}

      # Policy overrides.
      assert @operations["incus_native_rebuild_instance"]["x-tama-destructive"] == true

      assert @operations["incus_native_update_instances"]["x-opsmaru-native"]["confirm"] ==
               %{"value" => "instances"}
    end

    test "no exported body schema can select another backend or carry its credentials" do
      source = @components["InstanceSource.Input"]["properties"]

      for field <- ~w(server secret certificate operation secrets protocol mode),
          do: refute(Map.has_key?(source, field), field)

      assert Map.has_key?(source, "alias") and Map.has_key?(source, "fingerprint")

      image = @components["ImagesPostSource.Input"]["properties"]
      for field <- ~w(server secret certificate url), do: refute(Map.has_key?(image, field))

      for name <- ~w(InstancePostTarget.Input StorageVolumePostTarget.Input BackupTarget.Input
                     ClusterPut.Input ImageExportPost.Input ClusterCertificatePut.Input) do
        refute Map.has_key?(@components, name), name
      end

      for {name, schema} <- @components, String.ends_with?(name, ".Input") do
        assert schema["additionalProperties"] == false, name
      end

      # No exported body can ask for a migration, whose pull mode returns
      # websocket secrets, whether or not the client method guards the field.
      for {name, schema} <- @components, String.ends_with?(name, ".Input") do
        refute Map.has_key?(schema["properties"], "migration"), name
      end
    end

    test "operation results declare their native operation identity" do
      for {id, operation} <- @operations do
        background? = operation["x-opsmaru-native"]["result"] == "operation"
        assert operation["x-tama-identity"] == ["operation_id"] == background?, id
      end
    end
  end

  describe "trust checks before any backend request" do
    test "an unknown or unavailable operation is refused", %{root: root} do
      {fixture, caller} = start(root)

      for name <- ~w(incus_native_nope incus_native_exec_instance incus_instance_list) do
        assert {:error, %{"kind" => "unknown_operation"}} = run(name, %{}, caller)
      end

      refute_received {:host, _}
      refute_backend(fixture)
    end

    test "composite scopes do not grant native access", %{root: root} do
      {fixture, caller} = start(root)

      for {name, input, required} <- [
            {"incus_native_get_instances", %{"instance_type" => ""}, "incus.native.read"},
            {"incus_native_delete_instance", %{"name" => "web", "confirm" => "web"},
             "incus.native.delete"},
            {"incus_native_get_certificates", %{}, "incus.native.admin"}
          ] do
        result = run(name, input, caller, Composite.scopes())

        assert {:error, %{"kind" => "permission_denied", "required_scope" => ^required}} = result
        valid!(name, result)
      end

      # Each native scope grants only its own operations.
      assert {:error, %{"kind" => "permission_denied"}} =
               run(
                 "incus_native_delete_instance",
                 %{"name" => "web", "confirm" => "web"},
                 caller,
                 Native.scopes() -- ["incus.native.delete"]
               )

      assert {:error, %{"kind" => "permission_denied"}} =
               run("incus_native_get_instance", %{"name" => "web"}, caller, nil)

      refute_received {:host, _}
      refute_backend(fixture)
    end

    test "input that does not match the schema is refused", %{root: root} do
      {fixture, caller} = start(root)

      for {name, input, path} <- [
            {"incus_native_get_instance", %{}, "/name"},
            {"incus_native_get_instance", %{"name" => ""}, "/name"},
            {"incus_native_get_instance", %{"name" => "web", "socket" => "/x"}, "/socket"},
            {"incus_native_get_instance", %{"name" => "web", "project" => "a/b"}, "/project"},
            {"incus_native_get_instances_all_projects",
             %{"instance_type" => "", "project" => "default"}, "/project"},
            {"incus_native_get_operation_wait", %{"uuid" => @uuid, "timeout" => 3601},
             "/timeout"},
            {"incus_native_create_instance", %{}, "/body"},
            {"incus_native_create_instance", %{"body" => %{"nope" => true}}, "/body/nope"},
            {"incus_native_create_instance", %{"body" => %{"start" => "yes"}}, "/body/start"},
            {"incus_native_patch_instance", %{"name" => "web", "body" => %{}}, "/etag"}
          ] do
        result = run(name, input, caller)
        assert {:error, %{"kind" => "invalid_input", "path" => ^path}} = result
        valid!(name, result)
      end

      assert {:error, %{"kind" => "invalid_input"}} =
               run("incus_native_get_instance", "web", caller)

      big = %{"name" => "web", "body" => %{"description" => String.duplicate("d", 70_000)}}

      assert {:error, %{"kind" => "invalid_input", "message" => "the input exceeds 65536 bytes"}} =
               run("incus_native_update_instance", Map.put(big, "confirm", "web"), caller)

      refute_received {:host, _}
      refute_backend(fixture)
    end

    test "a remote image source is rejected by the schema", %{root: root} do
      {fixture, caller} = start(root)

      for field <- ~w(server secret certificate operation) do
        body = %{"name" => "web", "source" => %{"type" => "image", field => "https://remote"}}
        path = "/body/source/" <> field

        assert {:error, %{"kind" => "invalid_input", "path" => ^path}} =
                 run("incus_native_create_instance", %{"body" => body}, caller)
      end

      refute_received {:host, _}
      refute_backend(fixture)
    end

    test "a rename cannot start a migration", %{root: root} do
      {fixture, caller} = start(root)

      for {name, input} <- [
            {"incus_native_rename_storage_pool_volume",
             %{"pool" => "default", "volType" => "custom", "name" => "v"}},
            {"incus_native_rename_storage_pool_volume_snapshot",
             %{
               "pool" => "default",
               "volumeType" => "custom",
               "volumeName" => "v",
               "snapshotName" => "s"
             }},
            {"incus_native_rename_instance", %{"name" => "web"}},
            {"incus_native_rename_instance_snapshot", %{"instance_name" => "web", "name" => "s"}}
          ],
          {field, value} <- [{"migration", true}, {"migration", false}, {"target", %{}}] do
        body = %{"name" => "renamed", field => value}
        path = "/body/" <> field

        assert {:error, %{"kind" => "invalid_input", "path" => ^path}} =
                 run(name, Map.put(input, "body", body), caller),
               name
      end

      assert {:error, %{"kind" => "invalid_input", "path" => "/body/source"}} =
               run(
                 "incus_native_rename_storage_pool_volume",
                 %{
                   "pool" => "default",
                   "volType" => "custom",
                   "name" => "v",
                   "body" => %{"name" => "renamed", "source" => %{"type" => "migration"}}
                 },
                 caller
               )

      refute_received {:host, _}
      refute_backend(fixture)
    end

    test "a destructive operation with the wrong confirmation is refused", %{root: root} do
      {fixture, caller} = start(root)

      result = run("incus_native_delete_instance", %{"name" => "web", "confirm" => "db"}, caller)
      assert {:error, %{"kind" => "confirmation_mismatch", "message" => message}} = result
      assert message =~ ~s("web")
      valid!("incus_native_delete_instance", result)

      for {name, input} <- [
            {"incus_native_delete_instance", %{"name" => "web", "confirm" => "yes"}},
            {"incus_native_delete_instance", %{"name" => "web", "confirm" => ""}},
            {"incus_native_update_server", %{"body" => %{}, "confirm" => "yes"}},
            {"incus_native_update_instances", %{"body" => %{}, "confirm" => "server"}},
            {"incus_native_update_instance_state",
             %{"name" => "web", "body" => %{"action" => "stop"}, "confirm" => "stop"}},
            {"incus_native_delete_storage_pool_volume",
             %{"pool" => "default", "volType" => "custom", "name" => "v", "confirm" => "default"}}
          ] do
        assert {:error, %{"kind" => "confirmation_mismatch"}} = run(name, input, caller), name
      end

      assert {:error, %{"kind" => "invalid_input", "path" => "/confirm"}} =
               run("incus_native_delete_instance", %{"name" => "web"}, caller)

      refute_received {:host, _}
      refute_backend(fixture)
    end

    test "restricted config or devices need the host's approval", %{root: root} do
      {fixture, caller} = start(root)

      update = fn body ->
        %{"name" => "web", "body" => body, "confirm" => "web"}
      end

      result =
        run("incus_native_update_instance", update.(%{"config" => %{"raw.lxc" => "x"}}), caller)

      assert {:error, %{"kind" => "restricted_input", "items" => ["config:raw.lxc"]}} = result
      valid!("incus_native_update_instance", result)

      assert_received {:host,
                       {:allow_restricted, "incus_native_update_instance", [config: "raw.lxc"]}}

      host_disk = %{
        "devices" => %{"host" => %{"type" => "disk", "source" => "/etc", "path" => "/mnt"}}
      }

      for {name, input} <- [
            {"incus_native_update_instance", update.(host_disk)},
            {"incus_native_patch_instance",
             %{
               "name" => "web",
               "etag" => "e",
               "body" => %{"config" => %{"security.privileged" => "true"}}
             }},
            {"incus_native_create_instance",
             %{"body" => %{"name" => "web", "config" => %{"raw.qemu" => "x"}}}},
            {"incus_native_create_profile",
             %{"body" => %{"name" => "p", "config" => %{"raw.lxc" => "x"}}}},
            {"incus_native_update_profile",
             %{"name" => "p", "confirm" => "p", "body" => host_disk}}
          ] do
        assert {:error, %{"kind" => "restricted_input"}} = run(name, input, caller), name
      end

      refute_received {:host, {:binding, _}}
      refute_received {:host, {:authorize, _, _}}
      refute_backend(fixture)
    end

    test "a missing, failing or refusing host denies", %{root: root} do
      {fixture, caller} = start(root)
      input = %{"name" => "web"}

      for host <- [nil, String, :not_a_module] do
        assert {:error, %{"kind" => "host_binding_failed"}} =
                 Native.run("incus_native_get_instance", input,
                   host: host,
                   caller: caller,
                   scopes: Native.scopes()
                 )
      end

      for binding <- [fn _ -> raise "boom" end, fn _ -> {:error, :none} end, fn _ -> :ok end] do
        assert {:error, %{"kind" => "host_binding_failed"}} =
                 run("incus_native_get_instance", input, %{caller | binding: binding})
      end

      for authorize <- [fn _, _ -> {:error, :no} end, fn _, _ -> raise "boom" end] do
        result =
          run("incus_native_get_instance", input, Map.put(caller, :authorize, authorize))

        assert {:error, %{"kind" => "unauthorized"}} = result
        valid!("incus_native_get_instance", result)
      end

      refute_backend(fixture)
    end

    test "the host sees the operation ID and validated input, in order", %{root: root} do
      {fixture, caller} =
        start(root, fn request ->
          if OperationsFixture.path(request) == "/1.0/instances/web",
            do: sync(%{"name" => "web"}),
            else: :next
        end)

      input = %{"name" => "web", "project" => "tenant"}
      assert {:ok, _} = run("incus_native_get_instance", input, caller)

      assert_received {:host, {:binding, "incus_native_get_instance"}}
      assert_received {:host, {:authorize, "incus_native_get_instance", ^input}}
      assert [%{method: "GET", target: "/1.0/instances/web?project=tenant"}] = backend(fixture)
    end
  end

  describe "execution" do
    test "a list result is the native envelope, from exactly one request", %{root: root} do
      instances = [
        %{"name" => "web", "type" => "container", "config" => nil, "future_field" => %{"a" => 1}},
        %{"name" => "vm", "type" => "virtual-machine", "profiles" => ["default"]}
      ]

      {fixture, caller} =
        start(root, fn request ->
          if OperationsFixture.path(request) == "/1.0/instances", do: sync(instances), else: :next
        end)

      result = run("incus_native_get_instances", %{"instance_type" => "container"}, caller)

      assert %{"kind" => "list", "metadata" => ^instances} =
               valid!("incus_native_get_instances", result)

      assert [%{method: "GET", target: target}] = backend(fixture)

      assert OperationsFixture.query(%{target: target}) ==
               %{"instance-type" => "container", "recursion" => "1"}
    end

    test "a model result carries the native ETag", %{root: root} do
      {_fixture, caller} =
        start(root, fn request ->
          if OperationsFixture.path(request) == "/1.0/instances/web",
            do: sync(%{"name" => "web", "status_code" => 103}, %{"etag" => "abc"}),
            else: :next
        end)

      result = run("incus_native_get_instance", %{"name" => "web"}, caller)

      assert %{"kind" => "model", "etag" => "abc", "metadata" => %{"name" => "web"}} =
               valid!("incus_native_get_instance", result)
    end

    test "names, sync and empty_sync results use their envelopes", %{root: root} do
      {fixture, caller} =
        start(root, fn request ->
          case {request.method, OperationsFixture.path(request)} do
            {"GET", "/1.0/profiles"} -> sync(["/1.0/profiles/default", "/1.0/profiles/web"])
            {"POST", "/1.0/profiles"} -> sync(nil)
            {"PATCH", "/1.0/instances/web"} -> sync(%{})
            _ -> :next
          end
        end)

      assert %{"kind" => "names", "metadata" => ["default", "web"]} =
               valid!(
                 "incus_native_get_profile_names",
                 run("incus_native_get_profile_names", %{}, caller)
               )

      create = %{
        "body" => %{"name" => "web", "description" => "d", "config" => %{"user.a" => "b"}}
      }

      assert %{"kind" => "sync"} =
               valid!(
                 "incus_native_create_profile",
                 run("incus_native_create_profile", create, caller)
               )

      patch = %{"name" => "web", "etag" => "abc", "body" => %{"description" => "new"}}

      assert valid!(
               "incus_native_patch_instance",
               run("incus_native_patch_instance", patch, caller)
             ) ==
               %{"kind" => "empty_sync"}

      assert [
               %{method: "GET"},
               %{method: "POST", body: body},
               %{method: "PATCH", headers: %{"if-match" => "abc"}, body: patched}
             ] = backend(fixture)

      assert Jason.decode!(body) == create["body"]
      assert Jason.decode!(patched) == %{"description" => "new"}
    end

    test "a background operation returns its identity without waiting", %{root: root} do
      {fixture, caller} =
        start(root, fn request ->
          if request.method == "DELETE", do: accepted(@uuid), else: :next
        end)

      result = run("incus_native_delete_instance", %{"name" => "web", "confirm" => "web"}, caller)

      assert %{"kind" => "operation", "operation_id" => @uuid, "operation" => operation} =
               valid!("incus_native_delete_instance", result)

      assert operation["id"] == @uuid and operation["status_code"] == 103
      assert [%{method: "DELETE", target: "/1.0/instances/web"}] = backend(fixture)
      refute Enum.any?(backend(fixture), &String.contains?(&1.target, "/operations/"))
    end

    test "a create sends the validated body once, over mutual HTTPS too", %{root: root} do
      for transport <- [:gen_tcp, :ssl] do
        {fixture, caller} =
          start(
            root,
            fn request -> if request.method == "POST", do: accepted(@uuid), else: :next end,
            transport: transport
          )

        body = %{
          "name" => "web",
          "source" => %{"type" => "image", "alias" => "debian/13"},
          "config" => %{"limits.cpu" => "2"},
          "profiles" => nil
        }

        input = %{"project" => "tenant", "body" => body}

        assert %{"kind" => "operation", "operation_id" => @uuid} =
                 valid!(
                   "incus_native_create_instance",
                   run("incus_native_create_instance", input, caller)
                 )

        assert [%{method: "POST", target: "/1.0/instances?project=tenant", body: sent}] =
                 backend(fixture)

        assert Jason.decode!(sent) == body
      end
    end

    test "a plain rename is sent once with only the new name", %{root: root} do
      {fixture, caller} =
        start(
          root,
          fn request ->
            case {request.method, OperationsFixture.path(request)} do
              {"POST", "/1.0/instances/web"} -> accepted(@uuid)
              {"POST", "/1.0/storage-pools/default/volumes/custom/v"} -> sync(nil)
              _ -> :next
            end
          end,
          extensions: ["storage", "storage_api_volume_rename"]
        )

      body = %{"name" => "renamed"}

      assert %{"kind" => "operation", "operation_id" => @uuid} =
               valid!(
                 "incus_native_rename_instance",
                 run("incus_native_rename_instance", %{"name" => "web", "body" => body}, caller)
               )

      volume = %{"pool" => "default", "volType" => "custom", "name" => "v", "body" => body}

      assert %{"kind" => "sync"} =
               valid!(
                 "incus_native_rename_storage_pool_volume",
                 run("incus_native_rename_storage_pool_volume", volume, caller)
               )

      assert [%{method: "POST", body: first}, %{method: "POST", body: second}] = backend(fixture)
      assert Jason.decode!(first) == body and Jason.decode!(second) == body
    end

    test "restricted input the host allows reaches the backend", %{root: root} do
      {fixture, caller} =
        start(root, fn request ->
          if request.method == "PUT", do: accepted(@uuid), else: :next
        end)

      input = %{"name" => "web", "confirm" => "web", "body" => %{"config" => %{"raw.lxc" => "x"}}}

      assert {:ok, %{"kind" => "operation"}} =
               run(
                 "incus_native_update_instance",
                 input,
                 Map.put(caller, :allow_restricted, true)
               )

      assert [%{method: "PUT", target: "/1.0/instances/web"}] = backend(fixture)
    end

    test "a native rejection keeps its status, code and message", %{root: root} do
      {fixture, caller} =
        start(root, fn request ->
          if OperationsFixture.path(request) == "/1.0/instances/gone",
            do: native_error(404, "Instance not found"),
            else: :next
        end)

      result = run("incus_native_get_instance", %{"name" => "gone"}, caller)

      assert %{"kind" => "native", "http_status" => 404, "message" => "Instance not found"} =
               valid!("incus_native_get_instance", result)

      assert [_] = backend(fixture)
    end

    test "a missing API extension fails without a request", %{root: root} do
      {fixture, caller} = start(root)

      assert {:error, %{"kind" => "unsupported_extension"}} =
               run("incus_native_get_network_acls", %{}, caller)

      assert backend(fixture) == []
    end

    test "a lost response after possible acceptance is uncertain and sent once", %{root: root} do
      truncated =
        "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: 400\r\n\r\n{\"type\":"

      {fixture, caller} =
        start(root, fn request ->
          if request.method in ["POST", "DELETE"], do: %{raw: truncated}, else: :next
        end)

      for {name, input} <- [
            {"incus_native_create_instance", %{"body" => %{"name" => "web"}}},
            {"incus_native_delete_instance", %{"name" => "web", "confirm" => "web"}}
          ] do
        result = run(name, input, caller)
        assert %{"kind" => "uncertain", "message" => message} = valid!(name, result)
        assert message =~ "not resent"
      end

      assert [%{method: "POST"}, %{method: "DELETE"}] = backend(fixture)
    end

    test "an accepted operation whose body cannot be decoded keeps its identity", %{root: root} do
      {fixture, caller} =
        start(root, fn request ->
          if request.method == "DELETE" do
            %{
              status: 202,
              body: %{
                type: "async",
                status_code: 100,
                operation: "/1.0/operations/" <> @uuid,
                metadata: %{"id" => 7}
              }
            }
          else
            :next
          end
        end)

      result = run("incus_native_delete_instance", %{"name" => "web", "confirm" => "web"}, caller)

      assert %{"kind" => "uncertain", "operation_id" => @uuid} =
               valid!("incus_native_delete_instance", result)

      assert [%{method: "DELETE"}] = backend(fixture)
    end

    test "a result over the output bound fails with output_limit", %{root: root} do
      large =
        for index <- 1..40,
            do: %{"name" => "i#{index}", "description" => String.duplicate("x", 8_000)}

      {fixture, caller} =
        start(root, fn request ->
          if OperationsFixture.path(request) == "/1.0/instances", do: sync(large), else: :next
        end)

      result = run("incus_native_get_instances", %{"instance_type" => ""}, caller)
      assert %{"kind" => "output_limit"} = valid!("incus_native_get_instances", result)
      assert [_] = backend(fixture)
    end
  end

  test "the error object is the shared composite one" do
    assert @components["Error"] == Fragments.error_schema()

    for {_, operation} <- @operations do
      assert operation["responses"]["default"]["content"]["application/json"]["schema"] ==
               %{"$ref" => "#/components/schemas/Error"}
    end
  end
end
