defmodule Opsmaru.Incus.OCIOriginReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Context
  alias Opsmaru.Incus.{Connection, Error, HTTP, OCI, RequestContext}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  @info_driver Path.expand("../../.integration/oci-origin-info-driver", __DIR__)
  @http_driver Path.expand("../../.integration/oci-origin-http-driver", __DIR__)

  defmodule NoCallAdapter do
    @behaviour Opsmaru.Incus.OCI.Adapter
    def inspect_image(_, _), do: raise("unexpected conversion adapter")
    def image_file(_, _, _), do: raise("unexpected conversion adapter")
    def cleanup(_, _, _), do: raise("unexpected conversion adapter")
  end

  setup_all do
    for {driver, source} <- [{@info_driver, "./origininfo"}, {@http_driver, "./httpclient"}] do
      {out, status} =
        System.cmd("mise", ["exec", "--", "go", "build", "-o", driver, source],
          cd: Path.expand("../reference", __DIR__),
          env: [{"GOTOOLCHAIN", "local"}],
          stderr_to_stdout: true
        )

      assert status == 0, out
    end

    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-oci-origin-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, identity: TLSIdentity.generate(root, "oci-origin", "localhost")}
  end

  test "native origin metadata and HTTP handle are passive and independent of credential files",
       %{identity: identity} do
    fixture = fixture(identity, fn _ -> %{status: 200, body: %{}} end)
    client = client(fixture, identity)

    expected =
      oracle(@info_driver, %{
        Protocol: "oci",
        URL: HTTPFixture.endpoint(fixture).url,
        CA: File.read!(identity.cafile)
      })

    for path <- [identity.cafile, identity.certfile, identity.keyfile], do: File.rm!(path)
    assert {:ok, info} = OCI.connection_info(client)

    actual = %{
      URL: info.url,
      Addresses: info.addresses,
      Certificate: info.certificate,
      Protocol: info.protocol,
      Project: info.project,
      Target: info.target,
      SocketPath: info.socket_path
    }

    assert Map.new(actual, fn {key, value} -> {Atom.to_string(key), value} end) == expected
    assert {:ok, %HTTP{client: ^client} = handle} = OCI.http_client(client)
    refute inspect(handle) =~ "private"
    assert HTTPFixture.requests(fixture) == []
    assert :ok = OCI.disconnect(client)
  end

  test "native OCI HTTP status, binary body, ETag and duplicate query requests agree", %{
    identity: identity
  } do
    bytes = <<0, 255, 128, 42>>
    path = "/v2/catalog?tag=a%2Bb&tag=second"

    for status <- [200, 305, 409] do
      fixture =
        fixture(identity, fn _ ->
          %{
            raw: [
              "HTTP/1.1 #{status} Fixture\r\nContent-Length: 4\r\nETag: native-origin\r\nLocation: https://other.invalid/v2/catalog\r\nConnection: close\r\n\r\n",
              bytes
            ]
          }
        end)

      client = client(fixture, identity)

      expected =
        oracle(@http_driver, %{
          protocol: "oci",
          url: HTTPFixture.endpoint(fixture).url,
          ca: File.read!(identity.cafile),
          cert: File.read!(identity.certfile),
          key: File.read!(identity.keyfile),
          method: "POST",
          path: path,
          body: Base.encode64(bytes),
          headers: %{"if-match" => "native"}
        })

      [native] = HTTPFixture.requests(fixture)

      assert {:ok, response} =
               OCI.http_request(client, "POST", path,
                 body: bytes,
                 headers: [{"if-match", "native"}]
               )

      assert response.status == expected["status"]
      assert response.body == Base.decode64!(expected["body"])
      assert HTTP.Response.header(response, "etag") == expected["etag"]
      assert response.connection == client.connection and response.identity == :verified
      [^native, actual] = HTTPFixture.requests(fixture)
      assert actual.target == native.target and actual.body == native.body
      assert actual.headers["if-match"] == native.headers["if-match"]
      refute actual.target =~ "project="
      refute Map.has_key?(actual.headers, "x-incus-authenticated")
    end
  end

  test "origin, host binding, path and byte budgets reject or fail visibly without conversion", %{
    identity: identity
  } do
    fixture =
      fixture(identity, fn _ ->
        %{
          raw:
            "HTTP/1.1 302 Found\r\nContent-Length: 8\r\nLocation: https://other.invalid/\r\n\r\nredirect"
        }
      end)

    client = client(fixture, identity)

    for path <- [
          "https://other.invalid/v2",
          "//other.invalid/v2",
          "/../v2",
          "/%2e%2e/v2",
          "/v2#fragment",
          "/v2?x=%0d%0a",
          "/v2?x=%xx",
          nil
        ] do
      assert {:error, %Error{kind: :invalid_path}} = OCI.http_request(client, "GET", path)
    end

    unavailable = %{client | context: %{client.context | ready?: fn -> false end}}
    assert {:error, %Error{kind: :host_not_ready}} = OCI.connection_info(unavailable)
    assert {:error, %Error{kind: :host_not_ready}} = OCI.http_request(unavailable, "GET", "/v2")
    mismatch = %{client | connection: %{client.connection | owner: :other}}
    assert {:error, %Error{kind: :owner_mismatch}} = OCI.connection_info(mismatch)
    assert {:error, %Error{kind: :owner_mismatch}} = OCI.http_request(mismatch, "GET", "/v2")
    unix = %{client | connection: Connection.unix!("/private/host-adapter.sock", owner: :fixture)}
    assert {:error, %Error{kind: :invalid_origin}} = OCI.connection_info(unix)
    assert {:error, %Error{kind: :invalid_origin}} = OCI.http_client(unix)
    assert {:error, %Error{kind: :invalid_origin}} = HTTP.client(unix)

    assert {:error, %Error{kind: :invalid_http_request}} =
             OCI.http_request(client, "POST", "/v2", body: "first", body: "second")

    bounded = %{client | connection: %{client.connection | max_request_bytes: 2}}

    assert {:error, %Error{kind: :invalid_http_request}} =
             OCI.http_request(bounded, "POST", "/v2", body: "large")

    assert HTTPFixture.requests(fixture) == []
    assert {:ok, %{status: 302}} = OCI.http_request(client, "GET", "/v2")
    assert length(HTTPFixture.requests(fixture)) == 1
    bounded = %{client | connection: %{client.connection | max_response_bytes: 2}}
    assert {:error, %Error{kind: :response_limit}} = OCI.http_request(bounded, "GET", "/v2")
    assert length(HTTPFixture.requests(fixture)) == 2
  end

  test "local cancellation preserves uncertain mutation outcome and one dispatched request", %{
    identity: identity
  } do
    parent = self()

    fixture =
      fixture(identity, fn _ ->
        send(parent, :dispatched)
        Process.sleep(200)
        %{status: 200, body: %{}}
      end)

    original = client(fixture, identity)
    scope = RequestContext.new!(timeout: 3_000)
    client = %{original | connection: Connection.with_context(original.connection, scope)}

    task =
      Task.async(fn -> OCI.http_request(client, "POST", "/v2/mutation", body: <<0, 255>>) end)

    assert_receive :dispatched, 1_000
    RequestContext.cancel(scope)
    assert {:error, %Error{kind: :uncertain}} = Task.await(task, 1_000)
    assert length(HTTPFixture.requests(fixture)) == 1
    assert original.connection.request_context == nil
  end

  defp client(fixture, identity) do
    connection =
      Connection.https!(HTTPFixture.endpoint(fixture).url,
        owner: :fixture,
        project: "private-project",
        member: "private-member",
        tls: [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
      )

    context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)

    OCI.new!(connection, context, NoCallAdapter, %{
      private: "adapter credentials",
      origin: "https://other.invalid"
    })
  end

  defp fixture(identity, handler),
    do:
      start_supervised!(
        {HTTPFixture,
         transport: :ssl, certfile: identity.certfile, keyfile: identity.keyfile, handler: handler},
        id: make_ref()
      )

  defp oracle(driver, input) do
    port = Port.open({:spawn_executable, driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)

      {^port, {:exit_status, status}} ->
        flunk("native OCI origin oracle failed #{status}: #{data}")
    after
      5_000 ->
        Port.close(port)
        flunk("native OCI origin oracle deadline")
    end
  end
end
