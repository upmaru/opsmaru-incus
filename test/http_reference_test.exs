defmodule Opsmaru.Incus.HTTPReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, HTTP, Server}
  alias Opsmaru.Incus.HTTP.Response
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  alias Plug.Conn.Status
  @driver Path.expand("../../.integration/incus-http-client", __DIR__)

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./httpclient"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-http-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:gen_tcp, :ssl], status <- [200, 202, 305, 409] do
    test "#{transport} #{status} raw native HTTP preserves binary body, ETag and at-most-once request",
         %{root: root} do
      compare(root, unquote(transport), unquote(status))
    end
  end

  defp compare(root, transport, status) do
    body = <<0, 255, 128, 13, 10, 42>>
    reply = raw(status, body, [{"etag", "\"native-http\""}])
    {fixture, client, endpoint, identity} = fixture(root, transport, fn _ -> reply end)
    path = "/1.0/opaque?project=project+%2B&target=member+%2B"

    input =
      Map.merge(endpoint, %{
        method: "POST",
        path: path,
        body: Base.encode64(body),
        authenticated: true,
        headers: %{"if-match" => "\"old\"", "content-type" => "application/octet-stream"}
      })

    result = native(tls_input(input, identity))
    assert result["status"] == status
    assert Base.decode64!(result["body"]) == body
    expected = List.last(HTTPFixture.requests(fixture))
    assert {:ok, handle} = HTTP.client(client)
    assert HTTPFixture.requests(fixture) == [expected]

    assert {:ok, response} =
             HTTP.request(handle, "POST", "/1.0/opaque",
               body: body,
               headers: [{"if-match", "\"old\""}, {"content-type", "application/octet-stream"}]
             )

    assert response.status == result["status"]
    assert response.body == body
    assert Response.header(response, "ETag") == result["etag"]
    assert response.connection == client.connection
    assert response.identity == :verified
    actual = List.last(HTTPFixture.requests(fixture))
    assert actual.target == expected.target
    assert actual.body == expected.body
    assert actual.headers["if-match"] == expected.headers["if-match"]
    assert actual.headers["x-incus-authenticated"] == expected.headers["x-incus-authenticated"]
    assert length(HTTPFixture.requests(fixture)) == 2
    refute inspect(handle) =~ "CERTIFICATE"
    refute inspect(response) =~ Base.encode64(body)
  end

  test "duplicate native headers and trailers remain separate and ordered", %{root: root} do
    {fixture, client, endpoint, identity} =
      fixture(root, :gen_tcp, fn _ ->
        %{
          raw:
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nETag: first\r\nETag: second\r\nTrailer: X-Result\r\n\r\n3\r\n" <>
              <<0, 255, 128>> <> "\r\n0\r\nX-Result: trailer\r\n\r\n"
        }
      end)

    expected =
      native(
        tls_input(
          Map.merge(endpoint, %{
            method: "GET",
            path: "/1.0/opaque?project=project+%2B&target=member+%2B",
            authenticated: true
          }),
          identity
        )
      )

    assert expected["etag"] == "first"
    {:ok, handle} = HTTP.client(client)
    assert {:ok, response} = HTTP.request(handle, "GET", "/1.0/opaque")
    assert response.body == <<0, 255, 128>>

    assert Enum.filter(response.headers, fn {key, _} -> key == "etag" end) == [
             {"etag", "first"},
             {"etag", "second"}
           ]

    assert Response.header(response, "ETag") == "first"
    assert Response.header(response, "X-Result") == nil
    assert Response.trailer(response, "X-Result") == "trailer"
    assert length(HTTPFixture.requests(fixture)) == 2
  end

  test "native JSON requests retain the first header ETag independently of trailers", %{
    root: root
  } do
    body = Jason.encode!(%{type: "sync", metadata: %{native: true}})
    size = Integer.to_string(byte_size(body), 16)

    {_, client, _, _} =
      fixture(root, :gen_tcp, fn _ ->
        %{
          raw:
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nETag: first\r\nETag: second\r\nTrailer: ETag\r\n\r\n#{size}\r\n#{body}\r\n0\r\nETag: trailer\r\n\r\n"
        }
      end)

    assert {:ok, response} = Incus.raw_query(client, "GET", "/1.0/raw")
    assert response.etag == "first"
    assert response.metadata == %{"native" => true}
  end

  test "all supported verbs and redirects preserve one explicit request", %{root: root} do
    {fixture, client, _, _} =
      fixture(root, :gen_tcp, fn request ->
        if request.method == "HEAD",
          do: raw(200, ""),
          else: raw(302, "raw", [{"location", "https://unselected.example/1.0"}])
      end)

    {:ok, handle} = HTTP.client(client)

    for method <- ~w(GET HEAD POST PUT PATCH DELETE OPTIONS) do
      assert {:ok, response} = HTTP.request(handle, method, "/1.0/raw")
      assert response.status == if(method == "HEAD", do: 200, else: 302)
    end

    assert Enum.map(HTTPFixture.requests(fixture), & &1.method) ==
             ~w(GET HEAD POST PUT PATCH DELETE OPTIONS)
  end

  test "invalid requests and unready/mismatched hosts cannot contact the backend", %{root: root} do
    {fixture, client, _, _} = fixture(root, :gen_tcp, fn _ -> %{status: 200, body: "raw"} end)
    {:ok, handle} = HTTP.client(client)

    for opts <- [
          [body: %{}],
          [headers: [{"authorization", "private"}]],
          [headers: [{"x-test", "bad\r\nvalue"}]],
          [body: "one", body: "two"],
          [headers: [{"x-incus-authenticated", "false"}]],
          [unknown: true],
          %{}
        ] do
      assert {:error, %Error{kind: :invalid_http_request}} =
               HTTP.request(handle, "POST", "/1.0/raw", opts)
    end

    for path <- [
          "https://other.example/1.0",
          "//other.example/1.0",
          "/other",
          "/1.0?project=override"
        ] do
      assert {:error, %Error{}} = HTTP.request(handle, "GET", path)
    end

    for context <- [
          %{client.context | ready?: fn -> false end},
          %{client.context | owner: :other}
        ] do
      {:ok, handle} = HTTP.client(%{client | context: context})
      assert {:error, %Error{}} = HTTP.request(handle, "GET", "/1.0/raw")
    end

    assert HTTPFixture.requests(fixture) == []
  end

  test "request/response limits and response loss fail without replay", %{root: root} do
    {fixture, client, _, _} =
      fixture(root, :gen_tcp, fn _ -> %{status: 200, body: "too large"} end)

    client = %{
      client
      | connection: %{client.connection | max_request_bytes: 3, max_response_bytes: 3}
    }

    {:ok, handle} = HTTP.client(client)

    assert {:error, %Error{kind: :invalid_http_request}} =
             HTTP.request(handle, "POST", "/1.0/raw", body: <<0, 1, 2, 3>>)

    assert HTTPFixture.requests(fixture) == []

    assert {:error, %Error{kind: :uncertain}} =
             HTTP.request(handle, "POST", "/1.0/raw", body: <<0, 1, 2>>)

    assert length(HTTPFixture.requests(fixture)) == 1
    {lost, client, _, _} = fixture(root, :gen_tcp, fn _ -> %{raw: ""} end)
    {:ok, handle} = HTTP.client(client)
    assert {:error, %Error{kind: :uncertain}} = HTTP.request(handle, "DELETE", "/1.0/raw")
    assert length(HTTPFixture.requests(lost)) == 1
  end

  test "silent responses have a bounded deadline and independent handles retain their own origin",
       %{root: root} do
    {silent, client, _, _} = fixture(root, :gen_tcp, fn _ -> %{wire_chunks: [{1000, ""}]} end)
    client = %{client | connection: %{client.connection | timeout: 200}}
    {:ok, handle} = HTTP.client(client)
    started = System.monotonic_time(:millisecond)
    assert {:error, %Error{kind: :uncertain}} = HTTP.request(handle, "POST", "/1.0/raw")
    assert System.monotonic_time(:millisecond) - started < 1500
    assert length(HTTPFixture.requests(silent)) == 1

    for label <- ["one", "two"] do
      {fixture, client, _, _} = fixture(root, :gen_tcp, fn _ -> raw(200, label) end)
      {:ok, handle} = HTTP.client(client)
      assert {:ok, response} = HTTP.request(handle, "GET", "/1.0/raw")
      assert response.body == label
      assert response.connection.address == HTTPFixture.endpoint(fixture).socket
    end
  end

  defp raw(status, body, headers \\ []) do
    head = Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

    %{
      raw:
        "HTTP/1.1 #{status} #{Status.reason_phrase(status)}\r\nContent-Length: #{byte_size(body)}\r\n#{head}\r\n" <>
          body
    }
  end

  defp fixture(root, transport, handler) do
    identity =
      if transport == :ssl, do: TLSIdentity.generate(root, "http", "localhost"), else: nil

    opts =
      if identity,
        do: [certfile: identity.certfile, keyfile: identity.keyfile],
        else: [path: Path.join(root, "s-#{System.unique_integer([:positive])}")]

    fixture =
      start_supervised!({HTTPFixture, [transport: transport, handler: handler] ++ opts},
        id: make_ref()
      )

    endpoint = HTTPFixture.endpoint(fixture)

    connection =
      if identity,
        do:
          Connection.https!(endpoint.url,
            owner: :fixture,
            project: "project +",
            member: "member +",
            require_authenticated: true,
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          ),
        else:
          Connection.unix!(endpoint.socket,
            owner: :fixture,
            project: "project +",
            member: "member +",
            require_authenticated: true
          )

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{}
    }

    {fixture, client, endpoint, identity}
  end

  defp tls_input(input, nil), do: input

  defp tls_input(input, identity),
    do:
      Map.merge(input, %{
        ca: File.read!(identity.cafile),
        cert: File.read!(identity.certfile),
        key: File.read!(identity.keyfile),
        server_cert: File.read!(identity.certfile)
      })

  defp native(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    out = collect(port, "")
    Jason.decode!(out)
  end

  defp collect(port, out) do
    receive do
      {^port, {:data, bytes}} -> collect(port, out <> bytes)
      {^port, {:exit_status, 0}} -> out
      {^port, {:exit_status, code}} -> flunk("native HTTP oracle exit #{code}: #{out}")
    after
      5000 ->
        Port.close(port)
        flunk("native HTTP oracle deadline")
    end
  end
end
