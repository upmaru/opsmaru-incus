defmodule Opsmaru.Incus.GatewayOperationSecretTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.Incus.Gateway.{Policy, Request}
  alias Opsmaru.Incus.Upgrade
  alias Opsmaru.TestSupport.{HTTPFixture, WebSocketFixture}

  defmodule Host do
    @behaviour Opsmaru.Incus.Gateway.Host
    def ready?(_), do: true
    def authorize(_, config), do: config.authorization
    def valid?(request, grant, config), do: config.valid.(request, grant)

    def admit_operation_secret(request, config) do
      send(config.observer, {:secret_admission, request})
      config.admit.(request)
    end
  end

  setup context do
    observer = self()

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(context.root, "operation.sock"),
         handler: fn request ->
           if URI.decode_query(URI.parse(request.target).query || "")["secret"] == "native+secret" do
             %{
               upgrade: fn transport, socket ->
                 accept =
                   Base.encode64(
                     :crypto.hash(
                       :sha,
                       request.headers["sec-websocket-key"] <>
                         "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                     )
                   )

                 transport.send(socket, [
                   "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
                   accept,
                   "\r\n\r\n",
                   WebSocketFixture.frame(2, <<255, 0, 128>>)
                 ])

                 send(observer, {:operation_backend_closed, transport.recv(socket, 0, 3_000)})
               end
             }
           else
             %{
               status: 403,
               body: %{type: "error", error_code: 403, error: "native secret refused"}
             }
           end
         end}
      )

    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture)
    gateway = mount(context, connection)

    config = %{
      observer: self(),
      authorization: {:error, :unauthenticated},
      admit: fn request ->
        if request.operation == "migration" and request.project == "allowed" and
             request.peer.address == {127, 0, 0, 1},
           do: {:ok, :migration_grant},
           else: {:error, :forbidden}
      end,
      valid: fn _, grant -> grant == :migration_grant end
    }

    gateway = %{gateway | host: Host, host_config: config}
    GatewayServer.put_gateway(gateway)
    %{gateway: gateway, fixture: fixture}
  end

  test "only the named operation/project reaches backend; backend validates original secret",
       context do
    for target <- [
          "/1.0/operations/other/websocket?project=allowed&secret=native%2Bsecret",
          "/1.0/operations/migration/websocket?project=wrong&secret=native%2Bsecret",
          "/1.0/operations/migration/websocket?secret=native%2Bsecret"
        ] do
      assert {403, _} = negotiate(context.port, target)
    end

    assert HTTPFixture.requests(context.fixture) == []

    assert {403, body} =
             negotiate(
               context.port,
               "/1.0/operations/migration/websocket?project=allowed&secret=wrong"
             )

    assert Jason.decode!(body)["error"] == "native secret refused"

    assert {101, _} =
             negotiate(
               context.port,
               "/1.0/operations/migration/websocket?project=allowed&secret=native%2Bsecret"
             )

    assert [wrong, valid] = HTTPFixture.requests(context.fixture)
    assert URI.parse(wrong.target).query == "project=allowed&secret=wrong"
    assert URI.parse(valid.target).query == "project=allowed&secret=native%2Bsecret"
    assert_received {:secret_admission, request}
    refute inspect(request) =~ "secret="
    refute inspect(context.gateway) =~ "native+secret"
  end

  test "wrong methods protocols routes aliases and ambiguous secrets cannot invoke special admission",
       context do
    for {method, protocol, target} <- [
          {"GET", :http, "/1.0/operations/migration/websocket?secret=s"},
          {"POST", :websocket, "/1.0/operations/migration/websocket?secret=s"},
          {"GET", :raw, "/1.0/operations/migration/websocket?secret=s"},
          {"GET", :websocket, "/1.0/events?secret=s"},
          {"GET", :websocket, "/1.0/operations/migration/wait?secret=s"},
          {"GET", :websocket, "/1.0/operations/migration/websocket/extra?secret=s"},
          {"GET", :websocket, "/1.0/operations/migration%2Fother/websocket?secret=s"},
          {"GET", :websocket, "/1.0/operations/migration/websocket"},
          {"GET", :websocket, "/1.0/operations/migration/websocket?secret="},
          {"GET", :websocket, "/1.0/operations/migration/websocket?secret=s&secret=s"},
          {"GET", :websocket, "/1.0/operations/migration/websocket?secret=s&%73ecret=t"},
          {"GET", :websocket, "/1.0/operations/migration/websocket?secret=s&all-projects=true"}
        ] do
      request = request(method, protocol, target)
      assert {:error, %{status: 403}} = Policy.admit(context.gateway, request), target
    end

    refute_received {:secret_admission, _}
    assert HTTPFixture.requests(context.fixture) == []
    assert Admission.count(context.admission) == 0
  end

  test "explicit denial cannot fall through, and absent malformed late callbacks fail closed",
       context do
    request =
      request("GET", :websocket, "/1.0/operations/migration/websocket?project=allowed&secret=s")

    denied = %{
      context.gateway
      | host_config: %{context.gateway.host_config | authorization: {:error, :forbidden}}
    }

    assert {:error, %{status: 403}} = Policy.admit(denied, request)
    refute_received {:secret_admission, _}

    # The ordinary fixture host intentionally does not implement the optional callback.
    missing = %{
      context.gateway
      | host: GatewayHost,
        host_config: %{
          ready: true,
          observer: self(),
          authorize: fn _ -> {:error, :unauthenticated} end
        }
    }

    assert {:error, %{status: 403}} = Policy.admit(missing, request)

    for callback <- [
          fn _ -> true end,
          fn _ -> {:ok} end,
          fn _ -> raise "secret must not leak" end,
          fn _ -> exit(:private_secret) end,
          fn _ ->
            Process.sleep(200)
            {:ok, :migration_grant}
          end
        ] do
      gateway = %{
        context.gateway
        | callback_timeout: 25,
          host_config: %{context.gateway.host_config | admit: callback}
      }

      assert {:error, %{status: 403} = failure} = Policy.admit(gateway, request)
      refute inspect(failure) =~ "private_secret"
    end

    assert HTTPFixture.requests(context.fixture) == []
    assert Admission.count(context.admission) == 0
  end

  test "the original request and special grant use ordinary validity checks", context do
    request =
      request("GET", :websocket, "/1.0/operations/migration/websocket?project=allowed&secret=s")

    observer = self()

    config = %{
      context.gateway.host_config
      | valid: fn current, grant ->
          send(observer, {:valid, current, grant})
          current == request and grant == :migration_grant
        end
    }

    gateway = %{context.gateway | host_config: config}
    assert {:ok, admitted} = Policy.admit(gateway, request)
    assert_received {:valid, ^request, :migration_grant}
    assert :ok = Policy.recheck(gateway, request, admitted.grant)
    revoked = %{gateway | host_config: %{config | valid: fn _, _ -> false end}}
    assert {:error, %{status: 403}} = Policy.recheck(revoked, request, admitted.grant)
    Policy.release(admitted)
    assert HTTPFixture.requests(context.fixture) == []
  end

  test "special grant revocation closes an active operation channel without cancellation",
       context do
    grant = :atomics.new(1, [])
    :atomics.put(grant, 1, 1)
    config = %{context.gateway.host_config | valid: fn _, _ -> :atomics.get(grant, 1) == 1 end}

    gateway = %{
      context.gateway
      | host_config: config,
        callback_timeout: 25,
        recheck_interval: 100
    }

    GatewayServer.put_gateway(gateway)

    {:ok, conn} =
      Mint.HTTP.connect(:http, "localhost", context.port, mode: :passive, protocols: [:http1])

    {:ok, conn, ref} =
      Mint.WebSocket.upgrade(
        :ws,
        conn,
        "/1.0/operations/migration/websocket?project=allowed&secret=native%2Bsecret",
        []
      )

    assert {:ok, conn, 101, _, _} =
             Upgrade.receive_response(
               conn,
               ref,
               System.monotonic_time(:millisecond) + 3_000,
               1_048_576
             )

    assert Admission.count(context.admission) == 1
    :atomics.put(grant, 1, 0)
    # Graceful close frames and bounded forced EOF are both terminal under the
    # ordinary lease; neither sends an Incus DELETE for the pending operation.
    await_released(context.admission)
    Mint.HTTP.close(conn)
    assert_received {:operation_backend_closed, {:error, :closed}}
    assert [request] = HTTPFixture.requests(context.fixture)
    assert request.method == "GET"
  end

  test "malformed queries fail before special admission", context do
    for query <- ["secret=%zz", "secret=s&project=a&project=b", "secret=s;project=allowed"] do
      assert {400, _} = negotiate(context.port, "/1.0/operations/migration/websocket?" <> query)
    end

    refute_received {:secret_admission, _}
    assert HTTPFixture.requests(context.fixture) == []
  end

  defp await_released(admission, remaining \\ 100)
  defp await_released(admission, 0), do: assert(Admission.count(admission) == 0)

  defp await_released(admission, remaining) do
    if Admission.count(admission) == 0 do
      :ok
    else
      Process.sleep(10)
      await_released(admission, remaining - 1)
    end
  end

  defp request(method, protocol, target) do
    uri = URI.parse(target)

    assert {:ok, %Request{} = request} =
             Policy.request(%{
               method: method,
               protocol: protocol,
               path: uri.path,
               query: uri.query || "",
               peer: %{address: {127, 0, 0, 1}, port: 1, certificate: nil}
             })

    request
  end

  defp negotiate(port, target) do
    {:ok, conn} =
      Mint.HTTP.connect(:http, "localhost", port,
        mode: :passive,
        protocols: [:http1],
        skip_target_validation: true
      )

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, target, [])

    {:ok, conn, status, _headers, data} =
      Upgrade.receive_response(conn, ref, System.monotonic_time(:millisecond) + 3_000, 1_048_576)

    Mint.HTTP.close(conn)
    {status, IO.iodata_to_binary(Enum.reverse(data))}
  end
end
