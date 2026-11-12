defmodule Opsmaru.Incus.OperationsHostTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Context, Operations}
  alias Opsmaru.TestSupport.{OperationsFixture, OperationsHost}
  import OperationsFixture, only: [sync: 1]

  @all Operations.scopes()

  setup do
    root = OperationsFixture.root()
    on_exit(fn -> File.rm_rf!(root) end)

    fixture =
      OperationsFixture.start(root, :gen_tcp, fn request ->
        case OperationsFixture.path(request) do
          "/1.0/instances" -> sync([])
          "/1.0/instances/web" -> sync(%{"name" => "web", "type" => "container"})
          _ -> :next
        end
      end)

    %{
      fixture: fixture,
      caller: %{binding: {fixture.connection, fixture.context}, test_pid: self()}
    }
  end

  defp run(name, input, caller, scopes \\ @all),
    do: Operations.run(name, input, host: OperationsHost, caller: caller, scopes: scopes)

  defp refute_backend(fixture), do: assert(OperationsFixture.requests(fixture) == [])

  describe "host binding" do
    test "a missing host or callback denies before any backend request", %{fixture: fixture} do
      for host <- [nil, String, :not_a_module] do
        assert {:error, %{"kind" => "host_binding_failed"}} =
                 Operations.run("incus_instance_list", %{}, host: host, caller: %{}, scopes: @all)
      end

      refute_backend(fixture)
    end

    test "a raising, exiting or malformed binding denies", %{fixture: fixture, caller: caller} do
      bindings = [
        fn _ -> raise "boom" end,
        fn _ -> exit(:boom) end,
        fn _ -> throw(:boom) end,
        fn _ -> {:ok, :not_a_client} end,
        fn _ -> {:ok, fixture.connection, :not_a_context} end,
        fn _ -> {:error, :no_backend} end,
        fn _ -> :ok end
      ]

      for binding <- bindings do
        assert {:error, %{"kind" => "host_binding_failed"}} =
                 run("incus_instance_list", %{}, %{caller | binding: binding})
      end

      refute_backend(fixture)
    end

    test "a failing or raising authorization denies", %{fixture: fixture, caller: caller} do
      for authorize <- [
            fn _, _ -> {:error, :forbidden} end,
            fn _, _ -> raise "boom" end,
            fn _, _ -> :yes end
          ] do
        assert {:error, %{"kind" => "unauthorized"}} =
                 run(
                   "incus_instance_get",
                   %{"name" => "web"},
                   Map.put(caller, :authorize, authorize)
                 )
      end

      refute_backend(fixture)
    end

    test "an unauthorized project is denied with zero requests", %{
      fixture: fixture,
      caller: caller
    } do
      caller =
        Map.put(caller, :authorize, fn _, input ->
          if Map.get(input, "project", "default") == "default", do: :ok, else: {:error, :project}
        end)

      assert {:error, %{"kind" => "unauthorized"}} =
               run("incus_instance_list", %{"project" => "other"}, caller)

      assert_received {:host, {:authorize, "incus_instance_list", %{"project" => "other"}}}
      refute_backend(fixture)

      assert {:ok, %{"items" => []}} = run("incus_instance_list", %{}, caller)

      assert [%{target: "/1.0"}, %{target: "/1.0/instances?recursion=1"}] =
               OperationsFixture.requests(fixture)
    end

    test "the project is selected only after authorization", %{fixture: fixture, caller: caller} do
      assert {:ok, _} = run("incus_instance_list", %{"project" => "p1"}, caller)
      assert_received {:host, {:binding, "incus_instance_list"}}
      assert_received {:host, {:authorize, "incus_instance_list", %{"project" => "p1"}}}

      assert [discovery, list] = OperationsFixture.requests(fixture)
      assert discovery.target == "/1.0"
      assert list.target == "/1.0/instances?recursion=1&project=p1"
    end

    test "a host-supplied client skips rediscovery and keeps its trusted connection", %{
      fixture: fixture,
      caller: caller
    } do
      {:ok, client} = Incus.connect(fixture.connection, fixture.context)

      assert {:ok, %{"item" => %{"name" => "web"}}} =
               run("incus_instance_get", %{"name" => "web"}, %{caller | binding: client})

      assert [%{target: "/1.0"}, %{target: "/1.0/instances/web"}] =
               OperationsFixture.requests(fixture)
    end

    test "forged connection, URL, socket or owner input is rejected before the host is called", %{
      fixture: fixture,
      caller: caller
    } do
      forged = [
        %{"url" => "https://attacker.example:8443"},
        %{"socket" => "/var/lib/incus/unix.socket"},
        %{"owner" => "someone-else"},
        %{"connection" => %{"address" => "/tmp/other.sock"}},
        %{"target" => "member-2"}
      ]

      for extra <- forged, name <- ["incus_instance_list", "incus_instance_create"] do
        input = Map.merge(%{"name" => "x", "image" => %{"alias" => "a"}}, extra)
        input = if name == "incus_instance_list", do: extra, else: input
        assert {:error, %{"kind" => "invalid_input"}} = run(name, input, caller)
      end

      refute_received {:host, _}
      refute_backend(fixture)
    end

    test "an image remote is a host-approved name, never a URL", %{
      fixture: fixture,
      caller: caller
    } do
      input = %{"name" => "web", "image" => %{"alias" => "ubuntu/24.04", "remote" => "images"}}

      assert {:error, %{"kind" => "image_remote_unavailable"}} =
               run("incus_instance_create", input, caller)

      for source <- [
            %{"server" => "http://insecure", "protocol" => "simplestreams"},
            %{"server" => "https://x"}
          ] do
        assert {:error, %{"kind" => "image_remote_unavailable"}} =
                 run(
                   "incus_instance_create",
                   input,
                   Map.put(caller, :remotes, %{"images" => source})
                 )
      end

      url = %{input | "image" => %{"alias" => "a", "remote" => "https://images.example/"}}
      assert {:error, %{"kind" => "invalid_input"}} = run("incus_instance_create", url, caller)
      refute_backend(fixture)
    end

    test "a host that is not ready denies before any request", %{fixture: fixture, caller: caller} do
      context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> false end)

      assert {:error, %{"kind" => "host_not_ready"}} =
               run("incus_server_get", %{}, %{caller | binding: {fixture.connection, context}})

      refute_backend(fixture)
    end
  end

  describe "scope and confirmation" do
    test "a read-only caller cannot reach any mutation", %{fixture: fixture, caller: caller} do
      for descriptor <- Operations.all(), descriptor.scope != "incus.read" do
        assert {:error, %{"kind" => "permission_denied", "required_scope" => scope}} =
                 run(descriptor.name, %{}, caller, ["incus.read"])

        assert scope == descriptor.scope
      end

      refute_received {:host, _}
      refute_backend(fixture)
    end

    test "each operation requires its own scope, not a broader-sounding one", %{
      fixture: fixture,
      caller: caller
    } do
      delete = %{"name" => "web", "confirm" => "web"}

      assert {:error, %{"kind" => "permission_denied"}} =
               run("incus_instance_delete", delete, caller, ["incus.write"])

      assert {:error, %{"kind" => "permission_denied"}} =
               run("incus_instance_exec", %{}, caller, ["incus.write", "incus.delete"])

      assert {:error, %{"kind" => "permission_denied"}} =
               run("incus_instance_list", %{}, caller, ["incus.write"])

      for scopes <- [nil, [], "incus.read", [:incus_read]] do
        assert {:error, %{"kind" => "permission_denied"}} =
                 run("incus_instance_list", %{}, caller, scopes)
      end

      refute_backend(fixture)
    end

    test "deletion without confirmation fails validation", %{fixture: fixture, caller: caller} do
      assert {:error, %{"kind" => "invalid_input", "path" => "/confirm"}} =
               run("incus_instance_delete", %{"name" => "web"}, caller)

      refute_backend(fixture)
    end

    test "a mismatched or inferred confirmation is refused", %{fixture: fixture, caller: caller} do
      cases = [
        {"incus_instance_delete", %{"name" => "web", "confirm" => "WEB"}},
        {"incus_instance_delete", %{"name" => "web", "confirm" => "yes"}},
        {"incus_instance_delete", %{"name" => "web", "confirm" => ""}},
        {"incus_instance_snapshot_delete",
         %{"instance" => "web", "name" => "s1", "confirm" => "s1"}},
        {"incus_instance_snapshot_restore",
         %{"instance" => "web", "snapshot" => "s1", "confirm" => "web"}},
        {"incus_image_delete", %{"fingerprint" => String.duplicate("a", 64), "confirm" => "aaaa"}}
      ]

      for {name, input} <- cases do
        assert {:error, %{"kind" => "confirmation_required", "message" => message}} =
                 run(name, input, caller)

        assert message =~ "confirm"
      end

      refute_received {:host, _}
      refute_backend(fixture)
    end

    test "image deletion needs the full fingerprint", %{fixture: fixture, caller: caller} do
      assert {:error, %{"kind" => "invalid_input", "path" => "/fingerprint"}} =
               run("incus_image_delete", %{"fingerprint" => "abc", "confirm" => "abc"}, caller)

      refute_backend(fixture)
    end
  end

  describe "restricted create and update input" do
    test "restricted config and devices need host approval", %{fixture: fixture, caller: caller} do
      inputs = [
        %{"config" => %{"raw.lxc" => "lxc.aa_profile=unconfined"}},
        %{"config" => %{"security.privileged" => "true"}},
        %{"config" => %{"security.idmap.isolated" => "false"}},
        %{"config" => %{"volatile.base_image" => "x"}},
        %{"devices" => %{"host" => %{"type" => "disk", "source" => "/etc", "path" => "/mnt"}}},
        %{
          "devices" => %{
            "pooled" => %{
              "type" => "disk",
              "pool" => "default",
              "source" => "/srv",
              "path" => "/mnt"
            }
          }
        },
        %{
          "devices" => %{"eth1" => %{"type" => "nic", "nictype" => "physical", "parent" => "en0"}}
        },
        %{"devices" => %{"gpu" => %{"type" => "gpu"}}},
        %{
          "devices" => %{
            "proxy" => %{
              "type" => "proxy",
              "listen" => "unix:/run/x",
              "connect" => "tcp:127.0.0.1:80"
            }
          }
        }
      ]

      for extra <- inputs do
        create = Map.merge(%{"name" => "web", "image" => %{"alias" => "a"}}, extra)

        assert {:error, %{"kind" => "restricted_input", "items" => [_ | _]}} =
                 run("incus_instance_create", create, caller)

        assert {:error, %{"kind" => "restricted_input"}} =
                 run("incus_instance_update", Map.put(extra, "name", "web"), caller)
      end

      refute_received {:host, {:binding, _}}
      refute_backend(fixture)
    end

    test "pool-backed disks and managed-network nics are not restricted" do
      input = %{
        "config" => %{"limits.cpu" => "2", "security.nesting" => "true"},
        "devices" => %{
          "root" => %{"type" => "disk", "pool" => "default", "path" => "/"},
          "data" => %{
            "type" => "disk",
            "pool" => "default",
            "source" => "data",
            "path" => "/data"
          },
          "eth0" => %{"type" => "nic", "network" => "incusbr0", "name" => "eth0"}
        }
      }

      assert Operations.Instances.restricted(input) == []
    end

    test "the host may allow restricted input explicitly", %{caller: caller} do
      create = %{"name" => "web", "image" => %{"alias" => "a"}, "config" => %{"raw.lxc" => "x"}}
      caller = Map.put(caller, :authorize, fn _, _ -> {:error, :stop_here} end)

      assert {:error, %{"kind" => "unauthorized"}} =
               run("incus_instance_create", create, Map.put(caller, :allow_restricted, true))

      assert_received {:host,
                       {:allow_restricted, "incus_instance_create", [{:config, "raw.lxc"}]}}
    end
  end
end
