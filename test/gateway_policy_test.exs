defmodule Opsmaru.Incus.GatewayPolicyTest do
  # Tasks 2.1 and 2.2: shared authorization/readiness/backend binding before any
  # backend access, and canonical root/API mounting beside host routes.
  use Opsmaru.TestSupport.GatewayCase, async: true

  alias Opsmaru.Incus.Gateway.Policy

  describe "selection parsing matches the backend's url.ParseQuery reading" do
    test "single selections, encodings and all-projects truthiness" do
      assert {:ok, %{project: "a b", target: "node/1", all_projects: false}} =
               Policy.selection("project=a+b&target=node%2F1&filter=x")

      assert {:ok, %{project: nil, target: nil, all_projects: false}} = Policy.selection("")
      assert {:ok, %{project: nil}} = Policy.selection("project=")

      for value <- ["true", "1", "yes", "on", "TRUE", "On"],
          do: assert({:ok, %{all_projects: true}} = Policy.selection("all-projects=" <> value))

      for value <- ["false", "0", "", "maybe"],
          do: assert({:ok, %{all_projects: false}} = Policy.selection("all-projects=" <> value))
    end

    test "duplicate, semicolon-separated or badly escaped queries are refused" do
      for query <- [
            "project=a&project=b",
            "project=a&project=a",
            "target=x&target=y",
            "all-projects=1&all-projects=0",
            # Go fails the whole query and the backend would use `default`.
            "project=a&x;y=1",
            "project=a;b",
            "project=%zz",
            "x=%4",
            "%=1&project=a"
          ] do
        assert {:error, %{status: 400}} = Policy.selection(query), query
      end
    end
  end

  describe "route checks" do
    test "only canonical native routes are relayed" do
      for path <- [
            "/",
            "/1.0",
            "/1.0/",
            "/1.0/instances/c1",
            "/1.0/instances/a%20b",
            "/1.0/images/aliases/ubuntu%2F22.04"
          ],
          do: assert(:ok = Policy.route(path), path)

      for path <- ["/incus/1.0", "/1.0x", "/internal/shutdown", "/2.0", ""],
          do: assert({:error, %{status: 404}} = Policy.route(path), path)

      for path <- [
            "/1.0/../internal/shutdown",
            "/1.0/%2e%2e/internal",
            "/1.0/instances/./c1",
            "/1.0/instances/a%00",
            "/1.0/instances/a\\b",
            "/1.0/instances/a%5Cb",
            "/1.0/instances/a%5cb",
            "/1.0/instances/a%00b",
            "/1.0/instances/%zz"
          ],
          do: assert({:error, %{status: 400}} = Policy.route(path), path)
    end
  end

  describe "denial before backend access" do
    setup context do
      {backend, connection} = backend(context, reply(200, %{"type" => "sync"}))
      %{backend: backend, connection: connection}
    end

    test "missing or wrong identity", context do
      mount(context, context.connection)

      for headers <- [[], [{"authorization", "Bearer wrong"}]] do
        response = get(context, "/1.0/instances", headers)
        assert response.status == 403
        assert native(response.body)["error_code"] == 403
        assert native(response.body)["metadata"]["gateway"]["outcome"] == "not_sent"
      end

      assert StreamBackend.accepted(context.backend) == 0
    end

    test "duplicate credentials never authorize as one of the copies", context do
      mount(context, context.connection)
      response = get(context, "/1.0", [auth(), {"authorization", "Bearer other"}])
      # Cowboy joins repeated fields; adapters that keep them separate get a
      # 400 from the gateway before the host is asked.
      assert response.status == 403
      assert_received {:host_authorize, request}
      assert request.authorization == "Bearer fixture-token, Bearer other"
      assert StreamBackend.accepted(context.backend) == 0
    end

    test "unauthorized project, all-projects and ambiguous selections", context do
      mount(context, context.connection)

      for {target, status} <- [
            {"/1.0/instances?project=other", 403},
            {"/1.0/instances?all-projects=true", 403},
            {"/1.0/instances?project=allowed&project=other", 400},
            {"/1.0/instances?project=allowed&x;y=1", 400}
          ] do
        assert get(context, target).status == status, target
      end

      assert StreamBackend.accepted(context.backend) == 0
      assert get(context, "/1.0/instances?project=allowed").status == 200
      assert StreamBackend.accepted(context.backend) == 1
    end

    test "the host sees the parsed selection and the actual peer, not request claims", context do
      mount(context, context.connection)

      get(context, "/1.0/operations/abc-123/wait?project=allowed&target=n1", [
        auth(),
        {"x-forwarded-for", "203.0.113.9"},
        {"forwarded", "for=203.0.113.9"},
        {"x-incus-project", "other"}
      ])

      assert_received {:host_authorize, request}
      assert request.project == "allowed"
      assert request.target == "n1"
      assert request.operation == "abc-123"
      assert request.peer.address == {127, 0, 0, 1}
      assert request.peer.certificate == nil
      assert request.path == "/1.0/operations/abc-123/wait"
      assert request.query == "project=allowed&target=n1"
    end

    test "a host that is not ready, or slow to answer, denies", context do
      for ready <- [false, fn -> raise "boom" end, fn -> :yes end] do
        mount(context, context.connection, host_config: %{ready: ready})
        assert get(context, "/1.0").status == 503
      end

      mount(context, context.connection,
        callback_timeout: 50,
        host_config: %{ready: fn -> Process.sleep(1_000) && true end}
      )

      {elapsed, response} = :timer.tc(fn -> get(context, "/1.0") end, :millisecond)
      assert response.status == 503
      assert elapsed < 900
      refute_received {:host_authorize, _}
      assert StreamBackend.accepted(context.backend) == 0
    end

    test "a late authorization is discarded and cannot authorize", context do
      parent = self()

      mount(context, context.connection,
        callback_timeout: 50,
        host_config: %{
          authorize: fn _ ->
            Process.sleep(300)
            send(parent, :late_callback_finished)
            {:ok, :late}
          end
        }
      )

      assert get(context, "/1.0").status == 403
      # The callback process was killed at its deadline.
      refute_receive :late_callback_finished, 400
      assert StreamBackend.accepted(context.backend) == 0
    end

    test "authorization callbacks returning anything else deny", context do
      for result <- [:ok, true, {:ok}, {:error, :forbidden}, nil] do
        mount(context, context.connection, host_config: %{authorize: fn _ -> result end})
        assert get(context, "/1.0").status == 403
      end

      mount(context, context.connection, host_config: %{authorize: fn _ -> exit(:boom) end})
      assert get(context, "/1.0").status == 403
      assert StreamBackend.accepted(context.backend) == 0
    end

    test "a missing admission denies with no backend", context do
      mount(context, context.connection)
      GatewayServer.put_gateway(%{GatewayServer.gateway() | admission: :missing_admission})
      assert get(context, "/1.0").status == 503
      assert StreamBackend.accepted(context.backend) == 0
    end

    test "an unconfigured gateway denies", context do
      GatewayServer.clear()
      assert get(context, "/1.0").status == 503
      assert StreamBackend.accepted(context.backend) == 0
    end

    test "upgrades are authorized before protocol negotiation or unsupported refusal", context do
      mount(context, context.connection)

      for {protocol, headers} <- [
            {"websocket", [{"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="}]},
            {"sftp", []},
            {"nbd", []}
          ] do
        upgrade = [{"connection", "upgrade"}, {"upgrade", protocol} | headers]
        assert get(context, "/1.0/instances/c1/sftp", upgrade).status == 403

        response = get(context, "/1.0/instances/c1/sftp", [auth() | upgrade])

        if protocol == "websocket" do
          assert response.status == 400
          assert native(response.body)["error"] == "Invalid WebSocket upgrade"
        else
          assert response.status == 501
          assert native(response.body)["error"] =~ "not implemented"
        end
      end

      assert StreamBackend.accepted(context.backend) == 0
    end
  end

  describe "canonical mounting" do
    test "encoded paths and raw queries reach the backend unchanged through forward", context do
      {_, connection} = backend(context, reply(200, %{"type" => "sync"}))
      mount(context, connection)

      target =
        "/1.0/instances/a%20b%2Bc/files?path=%2Fetc%2Fhosts&filter=name+eq+%22x%22&project=allowed&recursion=2"

      assert get(context, target).status == 200
      assert_receive {:backend_request, %{target: ^target, method: "GET"}}

      assert get(context, "/").status == 200
      refute_receive {:backend_request, %{target: "/"}}
      assert get(context, "/1.0/instances").status == 200
      assert_receive {:backend_request, %{target: "/1.0/instances"}}
    end

    test "unknown native routes are authorized and relayed like any other", context do
      {backend, connection} =
        backend(context, reply(404, %{"type" => "error", "error_code" => 404, "error" => "nope"}))

      mount(context, connection)
      assert get(context, "/1.0/not-in-any-catalogue", []).status == 403
      assert StreamBackend.accepted(backend) == 0
      response = get(context, "/1.0/not-in-any-catalogue")
      assert response.status == 404
      assert native(response.body) == %{"type" => "error", "error_code" => 404, "error" => "nope"}
    end

    test "host routes coexist and keep their own body parsing", context do
      {backend, connection} = backend(context, reply(200, %{}))
      mount(context, connection)

      runtime =
        RawHTTP.request(
          context.port,
          "POST",
          "/runtime",
          [{"content-type", "application/json"}],
          ~s({"ready":true})
        )

      assert runtime.status == 200
      assert native(runtime.body) == %{"runtime" => %{"ready" => true}}

      mcp = RawHTTP.request(context.port, "POST", "/mcp", [], "raw")
      assert {mcp.status, mcp.body} == {200, "mcp:raw"}
      assert get(context, "/elsewhere").body == "host route not found"
      assert StreamBackend.accepted(backend) == 0
    end

    test "a gateway mounted after a body parser refuses instead of relaying", context do
      {backend, connection} = backend(context, reply(200, %{}))
      mount(context, connection)

      response =
        RawHTTP.request(
          context.port,
          "POST",
          "/parsed",
          [auth(), {"content-type", "application/json"}],
          ~s({"name":"c1"})
        )

      assert response.status == 500
      assert native(response.body)["error"] =~ "before request body parsing"
      assert StreamBackend.accepted(backend) == 0
    end
  end
end
