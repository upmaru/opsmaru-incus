defmodule Opsmaru.Incus.GatewayReviewRegressionTest do
  use Opsmaru.TestSupport.GatewayCase, async: false
  @moduletag :capture_log

  alias Opsmaru.Incus.Gateway.{Identity, Local, Policy}

  defmodule BodyAdapter do
    def read_req_body(state, _opts) do
      send(state.observer, {:body_read, self()})

      receive do
        {:body, body} -> {:ok, body, state}
      end
    end

    def send_resp(state, status, _headers, body) do
      send(state.observer, {:local_response, status, IO.iodata_to_binary(body)})
      {:ok, nil, state}
    end
  end

  defp restarted(old, attempts \\ 100) do
    pid = Process.whereis(GatewayReviewAdmission)

    cond do
      is_pid(pid) and pid != old ->
        pid

      attempts == 0 ->
        flunk("admission did not restart")

      true ->
        Process.sleep(5)
        restarted(old, attempts - 1)
    end
  end

  defp local_request(anonymous) do
    {:ok, request} =
      Policy.request(%{
        protocol: :http,
        method: "POST",
        path: "/1.0/certificates",
        query: "",
        peer: %{},
        authorization: if(anonymous, do: nil, else: "Bearer fixture-token")
      })

    request
  end

  defp fixture(context) do
    observer = self()
    {backend, connection} = backend(context, reply(500, %{}))
    start_supervised!({Admission, name: GatewayReviewAdmission, max_exchanges: 1, id: :review})

    gateway =
      mount(context, connection,
        host_config: %{
          certificates: fn _, _, _, _ ->
            send(observer, :certificate_mutation)
            {:ok, %{}, []}
          end
        }
      )

    gateway = %{gateway | admission: GatewayReviewAdmission}
    GatewayServer.put_gateway(gateway)
    {backend, gateway}
  end

  for anonymous <- [false, true] do
    @anonymous anonymous
    test "#{if anonymous, do: "anonymous", else: "authenticated"} blocked certificate upload dies with its original admission",
         context do
      {backend, gateway} = fixture(context)
      observer = self()
      request = local_request(@anonymous)

      {holder, monitor} =
        spawn_monitor(fn ->
          {:ok, admitted} = Policy.admit(gateway, request)

          conn = %{
            Plug.Test.conn(:post, request.path)
            | req_headers: [{"content-length", "2"}],
              adapter: {BodyAdapter, %{observer: observer}}
          }

          try do
            Local.serve(conn, gateway, request, admitted)
          after
            Policy.release(admitted)
          end
        end)

      on_exit(fn -> Process.exit(holder, :kill) end)
      assert_receive {:body_read, ^holder}, 1000
      old = Process.whereis(GatewayReviewAdmission)
      assert Admission.count(old) == 1
      Process.exit(old, :kill)
      new = restarted(old)
      assert Admission.count(new) == 0
      # The stalled old holder must terminate even if no more body bytes arrive.
      assert_receive {:DOWN, ^monitor, :process, ^holder, _}, 500
      refute_received :certificate_mutation
      assert get(context, "/1.0/certificates").status == 200
      assert_received :certificate_mutation
      assert StreamBackend.accepted(backend) == 0
    end

    @anonymous anonymous
    test "#{if anonymous, do: "anonymous", else: "authenticated"} local request denies an admission lost before dispatch",
         context do
      {backend, gateway} = fixture(context)
      request = local_request(@anonymous)
      {:ok, admitted} = Policy.admit(gateway, request)
      old = Process.whereis(GatewayReviewAdmission)
      Process.exit(old, :kill)
      restarted(old)
      conn = Plug.Test.conn(:post, request.path, "{}")
      response = Local.serve(conn, gateway, request, admitted)
      assert response.status == 503
      assert native(response.resp_body)["metadata"]["gateway"]["outcome"] == "not_sent"
      refute_received :certificate_mutation
      assert StreamBackend.accepted(backend) == 0
    end
  end

  test "admission loss during a trust callback cannot return a successful response", context do
    {backend, gateway} = fixture(context)
    observer = self()

    gateway = %{
      gateway
      | host_config:
          Map.put(gateway.host_config, :certificates, fn _, _, _, _ ->
            send(observer, {:certificate_callback_ready, self()})

            receive do
              :complete -> {:ok, %{}, []}
            end
          end)
    }

    {holder, monitor} =
      spawn_monitor(fn ->
        request = local_request(false)
        {:ok, admitted} = Policy.admit(gateway, request)
        conn = Plug.Test.conn(:post, request.path, "{}")
        response = Local.serve(conn, gateway, request, admitted)
        send(observer, {:completed, response.status, native(response.resp_body)})
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    assert_receive {:certificate_callback_ready, callback}, 1000
    old = Process.whereis(GatewayReviewAdmission)
    Process.exit(old, :kill)
    send(callback, :complete)
    assert_receive {:completed, 503, body}, 500
    assert body["metadata"]["gateway"]["outcome"] == "uncertain"
    assert_receive {:DOWN, ^monitor, :process, ^holder, _}, 500
    refute_receive {:completed, 200, _}, 50
    assert StreamBackend.accepted(backend) == 0
  end

  test "anonymous discovery callback terminates when its admission restarts", context do
    {backend, gateway} = fixture(context)
    observer = self()

    gateway = %{
      gateway
      | host_config:
          Map.put(gateway.host_config, :identity, fn ->
            send(observer, {:identity_callback, self()})
            Process.sleep(:infinity)
          end)
    }

    GatewayServer.put_gateway(gateway)
    {transport, socket} = client = RawHTTP.connect(context.port)
    on_exit(fn -> transport.close(socket) end)
    RawHTTP.send!(client, RawHTTP.head("GET", "/1.0", []))
    assert_receive {:identity_callback, callback}, 1000
    callback_monitor = Process.monitor(callback)
    old = Process.whereis(GatewayReviewAdmission)
    Process.exit(old, :kill)
    restarted(old)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, _}, 500
    assert {:error, :closed} = transport.recv(socket, 0, 500)
    assert StreamBackend.accepted(backend) == 0
  end

  test "chunked server identity accepts trailers and drops original representation validators",
       context do
    envelope =
      Identity.envelope(%{
        "api_extensions" => ["certificate_update"],
        "environment" => %{
          "addresses" => ["10.0.2.15:8443"],
          "certificate" => "guest",
          "native" => "kept"
        }
      })

    body = Jason.encode!(envelope)

    {backend, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, [
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n",
          "etag: original-head\r\ntrailer: etag, digest, content-md5, x-native\r\n\r\n",
          Integer.to_string(byte_size(body), 16),
          "\r\n",
          body,
          "\r\n0\r\n",
          "etag: original-trailer\r\ndigest: original-digest\r\ncontent-md5: original-md5\r\nx-native: native-trailer\r\n\r\n"
        ])
      end)

    gateway = mount(context, connection)
    response = get(context, "/1.0", [auth(), {"te", "trailers"}])
    assert response.status == 200
    assert response.complete
    result = native(response.body)

    assert result["metadata"]["environment"] == %{
             "addresses" => gateway.host_config.identity.addresses,
             "certificate" => context.public_certificate,
             "native" => "kept"
           }

    for header <- ["etag", "digest", "content-md5", "x-native", "trailer"],
        do: assert(RawHTTP.header(response, header) == [])

    assert response.trailers == []
    assert StreamBackend.accepted(backend) == 1
  end

  test "unsafe identity trailers fail before any rewritten body is committed", context do
    body = Jason.encode!(Identity.envelope(%{"environment" => %{}}))

    {_, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, [
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n",
          Integer.to_string(byte_size(body), 16),
          "\r\n",
          body,
          "\r\n0\r\nx-bad: bad",
          <<1>>,
          "value\r\n\r\n"
        ])
      end)

    mount(context, connection)
    response = get(context, "/1.0")
    assert response.status == 502
    assert native(response.body)["type"] == "error"
    refute response.body =~ "BEGIN CERTIFICATE"
  end
end
