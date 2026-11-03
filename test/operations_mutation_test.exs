defmodule Opsmaru.Incus.OperationsMutationTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.Operations
  alias Opsmaru.Incus.Operations.Schema
  alias Opsmaru.TestSupport.{OperationsFixture, OperationsHost}

  import OperationsFixture,
    only: [sync: 1, sync: 2, native_error: 2, accepted: 1, operation: 2, operation: 3]

  @uuid "01234567-89ab-cdef-0123-456789abcdef"
  @op "/1.0/operations/" <> @uuid

  setup do
    root = OperationsFixture.root()
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # `final` is the status code the native wait reports (nil: answer with `wait`).
  defp start(root, transport, opts \\ []) do
    parent = self()
    final = Keyword.get(opts, :final, 200)

    routes = fn request ->
      send(parent, {:request, request.method, request.target})
      path = OperationsFixture.path(request)

      cond do
        custom = opts[:routes] && opts[:routes].(request) ->
          custom

        path == @op <> "/wait" ->
          Process.sleep(Keyword.get(opts, :wait_delay, 0))
          sync(operation(@uuid, final))

        request.method in ["POST", "PUT", "DELETE"] ->
          accepted(@uuid)

        true ->
          :next
      end
    end

    fixture = OperationsFixture.start(root, transport, routes, Keyword.take(opts, [:timeout]))
    {fixture, %{binding: {fixture.connection, fixture.context}}}
  end

  defp run(name, input, caller),
    do:
      Operations.run(name, input,
        host: OperationsHost,
        caller: caller,
        scopes: Operations.scopes()
      )

  defp mutations(fixture),
    do: Enum.reject(OperationsFixture.requests(fixture), &(&1.method in ["GET", "HEAD"]))

  defp valid!(name, result) do
    {:ok, descriptor} = Operations.fetch(name)
    assert :ok = Schema.validate(Operations.output_schema(descriptor), result)
    result
  end

  describe "bounded synchronous mutations" do
    for transport <- [:gen_tcp, :ssl] do
      test "create reports completion with the native operation identity over #{transport}", %{
        root: root
      } do
        {fixture, caller} = start(root, unquote(transport))

        input = %{
          "name" => "web",
          "type" => "virtual-machine",
          "image" => %{"alias" => "ubuntu/24.04"},
          "profiles" => ["default"],
          "config" => %{"limits.cpu" => "2"},
          "start" => true,
          "wait_seconds" => 5
        }

        assert {:ok, result} = run("incus_instance_create", input, caller)
        valid!("incus_instance_create", result)

        assert %{
                 "status" => "completed",
                 "operation_id" => @uuid,
                 "waited_seconds" => 5,
                 "wait_error" => nil
               } =
                 result

        assert result["operation"]["status_code"] == 200
        assert [post] = mutations(fixture)
        assert post.target == "/1.0/instances"

        assert Jason.decode!(post.body) == %{
                 "name" => "web",
                 "type" => "virtual-machine",
                 "source" => %{"type" => "image", "alias" => "ubuntu/24.04"},
                 "profiles" => ["default"],
                 "config" => %{"limits.cpu" => "2"},
                 "start" => true
               }

        assert List.last(OperationsFixture.requests(fixture)).target == @op <> "/wait?timeout=5"
      end
    end

    test "a host-approved image remote supplies server and protocol, never the input", %{
      root: root
    } do
      {fixture, caller} = start(root, :gen_tcp)
      source = %{"server" => "https://images.example", "protocol" => "simplestreams"}
      caller = Map.put(caller, :remotes, %{"images" => source})
      input = %{"name" => "web", "image" => %{"fingerprint" => "abc", "remote" => "images"}}

      assert {:ok, %{"status" => "completed"}} = run("incus_instance_create", input, caller)
      [post] = mutations(fixture)

      assert Jason.decode!(post.body)["source"] == %{
               "type" => "image",
               "fingerprint" => "abc",
               "server" => "https://images.example",
               "protocol" => "simplestreams",
               "mode" => "pull"
             }

      assert Jason.decode!(post.body)["type"] == "container"
    end

    test "a still-running operation is reported as running for later polling", %{root: root} do
      {_fixture, caller} = start(root, :gen_tcp, final: 103)
      input = %{"name" => "web", "image" => %{"alias" => "a"}, "wait_seconds" => 0}

      assert {:ok, %{"status" => "running", "operation_id" => @uuid, "waited_seconds" => 0}} =
               run("incus_instance_create", input, caller)

      assert_received {:request, "GET", @op <> "/wait?timeout=0"}

      assert {:ok, %{"status" => "running"}} =
               run("incus_operation_get", %{"operation_id" => @uuid}, start_get(root))
    end

    test "a failed operation is reported with its native error", %{root: root} do
      {_fixture, caller} = start(root, :gen_tcp, final: 400)

      assert {:ok,
              %{"status" => "failed", "operation" => %{"err" => "boom", "status_code" => 400}}} =
               run("incus_instance_state_update", %{"name" => "web", "action" => "start"}, caller)
    end

    test "a lost response after possible acceptance is uncertain and never resent", %{root: root} do
      truncated =
        "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: 400\r\n\r\n{\"type\":"

      {fixture, caller} =
        start(root, :gen_tcp,
          routes: fn request -> request.method == "POST" && %{raw: truncated} end
        )

      assert {:ok, result} =
               run(
                 "incus_instance_snapshot_create",
                 %{"instance" => "web", "name" => "s1"},
                 caller
               )

      valid!("incus_instance_snapshot_create", result)
      assert %{"status" => "uncertain", "operation_id" => nil, "operation" => nil} = result
      assert [%{method: "POST"}] = mutations(fixture)

      refute Enum.any?(
               OperationsFixture.requests(fixture),
               &String.contains?(&1.target, "/operations/")
             )
    end

    test "a native rejection before acceptance is a tool error and is not retried", %{root: root} do
      {fixture, caller} =
        start(root, :gen_tcp,
          routes: fn request ->
            request.method == "POST" && native_error(409, "Instance already exists")
          end
        )

      assert {:error,
              %{"kind" => "native", "http_status" => 409, "message" => "Instance already exists"}} =
               run(
                 "incus_instance_create",
                 %{"name" => "web", "image" => %{"alias" => "a"}},
                 caller
               )

      assert [_] = mutations(fixture)
    end

    test "the wait is capped by the host connection timeout and reported", %{root: root} do
      {_fixture, caller} = start(root, :gen_tcp, timeout: 3_000)

      assert {:ok, %{"status" => "completed", "waited_seconds" => 2}} =
               run(
                 "incus_instance_state_update",
                 %{"name" => "web", "action" => "stop", "wait_seconds" => 60},
                 caller
               )

      assert_received {:request, "GET", @op <> "/wait?timeout=2"}
    end

    test "a local deadline during the wait reports running, never cancellation", %{root: root} do
      {fixture, caller} = start(root, :gen_tcp, timeout: 1_500, wait_delay: 2_500)

      assert {:ok, result} =
               run(
                 "incus_instance_state_update",
                 %{"name" => "web", "action" => "restart"},
                 caller
               )

      valid!("incus_instance_state_update", result)

      assert %{
               "status" => "running",
               "operation_id" => @uuid,
               "wait_error" => "deadline",
               "waited_seconds" => 0
             } =
               result

      assert result["operation"]["status_code"] == 103
      assert [%{method: "PUT"}] = mutations(fixture)
    end

    test "state and snapshot bodies follow the native shapes", %{root: root} do
      {fixture, caller} = start(root, :gen_tcp)

      assert {:ok, _} =
               run(
                 "incus_instance_state_update",
                 %{"name" => "web", "action" => "stop", "force" => true},
                 caller
               )

      assert {:ok, _} = run("incus_instance_snapshot_create", %{"instance" => "web"}, caller)

      restore = %{
        "instance" => "web",
        "snapshot" => "s1",
        "stateful" => true,
        "confirm" => "web/s1"
      }

      assert {:ok, %{"status" => "completed"}} =
               run("incus_instance_snapshot_restore", restore, caller)

      assert [state, snapshot, put] = mutations(fixture)
      assert {state.method, state.target} == {"PUT", "/1.0/instances/web/state"}

      assert Jason.decode!(state.body) == %{
               "action" => "stop",
               "timeout" => -1,
               "force" => true,
               "stateful" => false
             }

      assert {snapshot.method, snapshot.target} == {"POST", "/1.0/instances/web/snapshots"}
      assert Jason.decode!(snapshot.body) == %{"name" => "", "stateful" => false}
      assert {put.method, put.target} == {"PUT", "/1.0/instances/web"}
      assert Jason.decode!(put.body) == %{"restore" => "s1", "stateful" => true}
    end
  end

  describe "conditional instance update" do
    test "uses the given ETag and sends only the present fields", %{root: root} do
      {fixture, caller} =
        start(root, :gen_tcp, routes: fn request -> request.method == "PATCH" && sync(%{}) end)

      input = %{
        "name" => "web",
        "etag" => "\"e1\"",
        "config" => %{"limits.cpu" => "4"},
        "description" => "d"
      }

      assert {:ok, result} = run("incus_instance_update", input, caller)
      valid!("incus_instance_update", result)
      assert %{"status" => "completed", "operation_id" => nil, "etag_source" => "input"} = result
      assert [patch] = mutations(fixture)

      assert {patch.method, patch.target, patch.headers["if-match"]} ==
               {"PATCH", "/1.0/instances/web", "\"e1\""}

      assert Jason.decode!(patch.body) == %{
               "config" => %{"limits.cpu" => "4"},
               "description" => "d"
             }
    end

    test "reads the current ETag when none is given", %{root: root} do
      routes = fn request ->
        case {request.method, request.target} do
          {"GET", "/1.0/instances/web"} -> sync(%{"name" => "web"}, %{"ETag" => "\"read\""})
          {"PATCH", _} -> sync(%{})
          _ -> nil
        end
      end

      {fixture, caller} = start(root, :gen_tcp, routes: routes)

      assert {:ok, %{"etag_source" => "read"}} =
               run("incus_instance_update", %{"name" => "web", "ephemeral" => true}, caller)

      assert [patch] = mutations(fixture)
      assert patch.headers["if-match"] == "\"read\""
    end

    test "a concurrent change fails natively and needs at least one field", %{root: root} do
      {_fixture, caller} =
        start(root, :gen_tcp,
          routes: fn request ->
            request.method == "PATCH" && native_error(412, "ETag doesn't match")
          end
        )

      assert {:error, %{"kind" => "native", "http_status" => 412}} =
               run(
                 "incus_instance_update",
                 %{"name" => "web", "etag" => "x", "profiles" => []},
                 caller
               )

      assert {:error, %{"kind" => "invalid_input", "message" => message}} =
               run("incus_instance_update", %{"name" => "web", "etag" => "x"}, caller)

      assert message =~ "at least one"
    end
  end

  describe "deletion" do
    test "confirmed deletions return native operation identity", %{root: root} do
      {fixture, caller} = start(root, :gen_tcp)
      fingerprint = String.duplicate("ab", 32)

      for {name, input} <- [
            {"incus_instance_delete", %{"name" => "web", "confirm" => "web"}},
            {"incus_instance_snapshot_delete",
             %{"instance" => "web", "name" => "s1", "confirm" => "web/s1"}},
            {"incus_image_delete", %{"fingerprint" => fingerprint, "confirm" => fingerprint}}
          ] do
        assert {:ok, result} = run(name, input, caller)
        assert %{"status" => "completed", "operation_id" => @uuid} = valid!(name, result)
      end

      assert Enum.map(mutations(fixture), &{&1.method, &1.target}) == [
               {"DELETE", "/1.0/instances/web"},
               {"DELETE", "/1.0/instances/web/snapshots/s1"},
               {"DELETE", "/1.0/images/" <> fingerprint}
             ]
    end

    test "native deletion errors are returned as they are", %{root: root} do
      {_fixture, caller} =
        start(root, :gen_tcp,
          routes: fn request ->
            request.method == "DELETE" && native_error(400, "Instance is running")
          end
        )

      assert {:error,
              %{"kind" => "native", "http_status" => 400, "message" => "Instance is running"}} =
               run("incus_instance_delete", %{"name" => "web", "confirm" => "web"}, caller)
    end
  end

  describe "operation get, wait and cancel by ID" do
    test "get and wait rebind a native operation by its UUID", %{root: root} do
      {fixture, caller} =
        start(root, :gen_tcp,
          final: 401,
          routes: fn request -> request.target == @op && sync(operation(@uuid, 200)) end
        )

      assert {:ok, %{"status" => "completed", "operation_id" => @uuid}} =
               run("incus_operation_get", %{"operation_id" => @uuid}, caller)

      assert {:ok,
              %{
                "status" => "failed",
                "operation" => %{"status" => "Cancelled"},
                "waited_seconds" => 3
              }} =
               run(
                 "incus_operation_wait",
                 %{"operation_id" => @uuid, "wait_seconds" => 3},
                 caller
               )

      assert mutations(fixture) == []

      assert {:error, %{"kind" => "invalid_input"}} =
               run("incus_operation_get", %{"operation_id" => "../instances"}, caller)
    end

    test "a local wait timeout is reported as running and sends no cancellation", %{root: root} do
      {fixture, caller} = start(root, :gen_tcp, timeout: 1_500, wait_delay: 2_500)

      assert {:ok, %{"status" => "running", "wait_error" => "deadline", "operation" => nil}} =
               run("incus_operation_wait", %{"operation_id" => @uuid}, caller)

      assert mutations(fixture) == []
    end

    test "cancel reports final, unsupported, requested and uncertain outcomes", %{root: root} do
      parent = self()

      cancel = fn snapshot, delete ->
        {fixture, caller} =
          start(root, :gen_tcp,
            routes: fn request ->
              case {request.method, request.target} do
                {"GET", @op} -> sync(snapshot)
                {"DELETE", @op} -> send(parent, :deleted) && delete
                _ -> nil
              end
            end
          )

        {run("incus_operation_cancel", %{"operation_id" => @uuid}, caller), mutations(fixture)}
      end

      assert {{:ok, %{"cancellation" => "already_final", "status" => "completed"}}, []} =
               cancel.(operation(@uuid, 200, %{"may_cancel" => true}), nil)

      assert {{:ok, %{"cancellation" => "unsupported", "status" => "running"}}, []} =
               cancel.(operation(@uuid, 103), nil)

      assert {{:ok, %{"cancellation" => "requested", "status" => "running"} = result}, [_]} =
               cancel.(operation(@uuid, 103, %{"may_cancel" => true}), sync(%{}))

      valid!("incus_operation_cancel", result)

      assert {{:ok, %{"cancellation" => "uncertain"}}, [_]} =
               cancel.(operation(@uuid, 103, %{"may_cancel" => true}), %{
                 raw: "HTTP/1.1 200 OK\r\nContent-Length: 90\r\n\r\n{"
               })

      assert {{:error, %{"kind" => "native", "http_status" => 403}}, [_]} =
               cancel.(
                 operation(@uuid, 103, %{"may_cancel" => true}),
                 native_error(403, "not allowed")
               )
    end
  end

  defp start_get(root) do
    {_fixture, caller} =
      start(root, :gen_tcp,
        routes: fn request -> request.target == @op && sync(operation(@uuid, 103)) end
      )

    caller
  end
end
