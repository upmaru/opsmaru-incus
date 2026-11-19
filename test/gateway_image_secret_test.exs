defmodule Opsmaru.Incus.GatewayImageSecretTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.Incus.Gateway.{Policy, Request}
  alias Opsmaru.TestSupport.HTTPFixture

  @fp String.duplicate("ab", 32)

  defmodule Host do
    @behaviour Opsmaru.Incus.Gateway.Host
    def ready?(_), do: true
    def authorize(_, config), do: config.authorization
    def valid?(_, grant, _), do: grant == :image_grant

    def admit_operation_secret(request, config) do
      send(config.observer, {:operation_admission, request})
      {:error, :forbidden}
    end

    def admit_image_secret(request, config) do
      send(config.observer, {:image_admission, request})
      config.admit.(request)
    end
  end

  setup context do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(context.root, "image.sock"),
         handler: fn _ -> %{status: 200, body: %{type: "sync", metadata: %{}}} end}
      )

    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture)

    gateway = %{
      mount(context, connection)
      | host: Host,
        host_config: %{
          observer: self(),
          authorization: {:error, :unauthenticated},
          admit: fn _ -> {:ok, :image_grant} end
        }
    }

    %{gateway: gateway, fixture: fixture}
  end

  test "only the exact pinned image secret routes carry image metadata" do
    for {method, target, headers, route, fingerprint} <- [
          {"GET", "/1.0/images/#{@fp}?secret=s", %{}, :info, @fp},
          {"GET", "/1.0/images/#{@fp}?project=p&secret=s", %{}, :info, @fp},
          {"GET", "/1.0/images/abc/export?secret=s", %{}, :export, "abc"},
          {"GET", "/1.0/operations/op-1/wait?secret=s&timeout=-1", %{}, :wait, nil},
          {"POST", "/1.0/images?project=p", %{secret: ["s"], fingerprint: [@fp]}, :upload, @fp}
        ] do
      assert %{route: ^route, fingerprint: ^fingerprint} =
               request(method, :http, target, headers).image,
             target
    end

    for {method, protocol, target, headers} <- [
          {"GET", :http, "/1.0/images/#{@fp}", %{}},
          {"GET", :http, "/1.0/images/#{@fp}?secret=", %{}},
          {"GET", :http, "/1.0/images/#{@fp}?secret=s&secret=s", %{}},
          {"GET", :http, "/1.0/images/#{@fp}?secret=s&%73ecret=t", %{}},
          {"GET", :http, "/1.0/images/ABCD?secret=s", %{}},
          {"GET", :http, "/1.0/images/#{String.duplicate("a", 65)}?secret=s", %{}},
          {"GET", :http, "/1.0/images/#{@fp}%2Fexport?secret=s", %{}},
          {"GET", :http, "/1.0/images/#{@fp}/export/extra?secret=s", %{}},
          {"GET", :http, "/1.0/images/#{@fp}/secret?secret=s", %{}},
          {"GET", :http, "/1.0/images/aliases/name?secret=s", %{}},
          {"DELETE", :http, "/1.0/images/#{@fp}?secret=s", %{}},
          {"PUT", :http, "/1.0/images/#{@fp}?secret=s", %{}},
          {"POST", :http, "/1.0/images/#{@fp}/export?secret=s", %{}},
          {"GET", :websocket, "/1.0/images/#{@fp}?secret=s", %{}},
          {"GET", :raw, "/1.0/images/#{@fp}/export?secret=s", %{}},
          {"GET", :http, "/1.0/operations/op-1?secret=s", %{}},
          {"GET", :http, "/1.0/operations/op-1/wait", %{}},
          {"GET", :http, "/1.0/operations/op%2F1/wait?secret=s", %{}},
          {"DELETE", :http, "/1.0/operations/op-1/wait?secret=s", %{}},
          {"POST", :http, "/1.0/images", %{}},
          {"POST", :http, "/1.0/images", %{secret: ["s"]}},
          {"POST", :http, "/1.0/images", %{fingerprint: [@fp]}},
          {"POST", :http, "/1.0/images", %{secret: [""], fingerprint: [@fp]}},
          {"POST", :http, "/1.0/images", %{secret: ["s", "t"], fingerprint: [@fp]}},
          {"POST", :http, "/1.0/images", %{secret: ["s"], fingerprint: [@fp, @fp]}},
          {"POST", :http, "/1.0/images", %{secret: ["s"], fingerprint: ["not-hex"]}},
          {"POST", :http, "/1.0/images?secret=s", %{secret: ["s"], fingerprint: [@fp]}},
          {"POST", :http, "/1.0/images/", %{secret: ["s"], fingerprint: [@fp]}}
        ] do
      assert request(method, protocol, target, headers).image == nil, target
    end
  end

  test "image routes invoke only the image callback and grant only that request", context do
    for {target, headers} <- [
          {"/1.0/images/#{@fp}?project=p&secret=s", %{}},
          {"/1.0/images/#{@fp}/export?project=p&secret=s", %{}},
          {"/1.0/operations/op-1/wait?secret=s&timeout=-1", %{}}
        ] do
      request = request("GET", :http, target, headers)
      assert {:ok, admitted} = Policy.admit(context.gateway, request)
      assert admitted.grant == :image_grant
      Policy.release(admitted)
      assert_received {:image_admission, ^request}
    end

    upload =
      request("POST", :http, "/1.0/images", %{secret: ["native-image-secret"], fingerprint: [@fp]})

    assert {:ok, admitted} = Policy.admit(context.gateway, upload)
    Policy.release(admitted)
    assert_received {:image_admission, ^upload}
    # The host gets the decoded secret to verify; inspection redacts it.
    assert upload.image == %{route: :upload, fingerprint: @fp, secret: "native-image-secret"}
    refute inspect(upload) =~ "native-image-secret"

    wait = request("GET", :http, "/1.0/operations/op-1/wait?secret=a%2Bb&timeout=-1")
    assert wait.image.secret == "a+b"

    # The migration route still uses only its own callback.
    websocket = request("GET", :websocket, "/1.0/operations/op-1/websocket?secret=s")
    assert {:error, %{status: 403}} = Policy.admit(context.gateway, websocket)
    assert_received {:operation_admission, ^websocket}
    refute_received {:image_admission, _}

    assert HTTPFixture.requests(context.fixture) == []
    assert Admission.count(context.admission) == 0
  end

  test "non-image routes and all-projects selections never reach the image callback",
       context do
    for {method, target, headers} <- [
          {"GET", "/1.0/images/#{@fp}", %{}},
          {"GET", "/1.0/images/#{@fp}?secret=s&all-projects=true", %{}},
          {"GET", "/1.0/images?secret=s", %{}},
          {"DELETE", "/1.0/images/#{@fp}?secret=s", %{}},
          {"POST", "/1.0/images", %{secret: ["s"]}},
          {"GET", "/1.0/instances?secret=s", %{}}
        ] do
      request = request(method, :http, target, headers)
      assert {:error, %{status: 403}} = Policy.admit(context.gateway, request), target
    end

    refute_received {:image_admission, _}
    assert HTTPFixture.requests(context.fixture) == []
    assert Admission.count(context.admission) == 0
  end

  test "explicit denial cannot fall through, and absent malformed late callbacks fail closed",
       context do
    request = request("GET", :http, "/1.0/images/#{@fp}/export?secret=s")

    denied = %{
      context.gateway
      | host_config: %{context.gateway.host_config | authorization: {:error, :forbidden}}
    }

    assert {:error, %{status: 403}} = Policy.admit(denied, request)
    refute_received {:image_admission, _}

    # The ordinary fixture host does not implement the optional callback.
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
          fn _ -> {:error, :forbidden} end,
          fn _ -> true end,
          fn _ -> {:ok} end,
          fn _ -> raise "secret must not leak" end,
          fn _ -> exit(:private_secret) end,
          fn _ ->
            Process.sleep(200)
            {:ok, :image_grant}
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

    # An admitted grant is still rechecked by valid?/3.
    revoked = %{
      context.gateway
      | host_config: %{context.gateway.host_config | admit: fn _ -> {:ok, :other_grant} end}
    }

    assert {:error, %{status: 403}} = Policy.admit(revoked, request)
    assert HTTPFixture.requests(context.fixture) == []
    assert Admission.count(context.admission) == 0
  end

  test "an image peer's upload may carry only the image, never an image request",
       context do
    GatewayServer.put_gateway(context.gateway)
    headers = [{"x-incus-secret", "s"}, {"x-incus-fingerprint", @fp}]
    json = Jason.encode!(%{source: %{type: "image", mode: "pull", server: "https://peer.test"}})

    # incusd picks the action from the body, whatever the content type says.
    for {content_type, body} <- [
          {"application/json", json},
          {"application/octet-stream", json},
          {"application/octet-stream", " \t\r\n" <> json},
          {"multipart/form-data; boundary=b", json},
          {"application/octet-stream", "\n--b\r\n"},
          {"application/octet-stream", ""}
        ] do
      response =
        RawHTTP.request(
          context.port,
          "POST",
          "/1.0/images",
          [{"content-type", content_type} | headers],
          body
        )

      assert response.status == 403, inspect({content_type, body})
      assert_received {:image_admission, %{image: %{route: :upload}}}
    end

    # Refused before the backend sees the request, so the secret is not consumed.
    assert HTTPFixture.requests(context.fixture) == []

    image = <<0xFD, "7zXZ", 0, "{not json}">>

    for {content_type, body} <- [
          {"application/octet-stream", image},
          {"multipart/form-data; boundary=b", "--b\r\n\r\n" <> image <> "\r\n--b--\r\n"}
        ] do
      response =
        RawHTTP.request(
          context.port,
          "POST",
          "/1.0/images",
          [{"content-type", content_type} | headers],
          body
        )

      assert response.status == 200
      assert [%{method: "POST", target: "/1.0/images"} = sent] = requests(context.fixture)
      assert sent.body == body
      assert sent.headers["x-incus-secret"] == "s"
    end

    # A caller the host authorizes itself is not limited, whatever headers it adds.
    GatewayServer.put_gateway(%{
      context.gateway
      | host_config: %{context.gateway.host_config | authorization: {:ok, :image_grant}}
    })

    response =
      RawHTTP.request(
        context.port,
        "POST",
        "/1.0/images",
        [{"content-type", "application/json"} | headers],
        json
      )

    assert response.status == 200
    assert [%{body: ^json}] = requests(context.fixture)
    assert Admission.count(context.admission) == 0
  end

  # The fixture keeps every request; take the ones since the last call.
  defp requests(fixture) do
    seen = Process.get(:seen_requests, 0)
    all = HTTPFixture.requests(fixture)
    Process.put(:seen_requests, length(all))
    Enum.drop(all, seen)
  end

  defp request(method, protocol, target, headers \\ %{}) do
    uri = URI.parse(target)

    assert {:ok, %Request{} = request} =
             Policy.request(%{
               method: method,
               protocol: protocol,
               path: uri.path,
               query: uri.query || "",
               peer: %{address: {127, 0, 0, 1}, port: 1, certificate: nil},
               image_headers: headers
             })

    request
  end
end
