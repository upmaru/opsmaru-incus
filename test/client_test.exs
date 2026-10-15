defmodule Opsmaru.Incus.ClientTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Response}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  setup do
    root = Path.join(System.tmp_dir!(), "op-client-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    context = Context.new!(owner: :host, identity: :verified, ready?: fn -> true end)
    %{root: root, context: context}
  end

  test "discovery preserves optional/null/unknown fields and rejects missing extensions", %{
    root: root,
    context: context
  } do
    fixture =
      backend(root, fn _ ->
        reply(%{
          "api_version" => "1.0",
          "api_extensions" => ["projects"],
          "environment" => nil,
          "new_field" => 7
        })
      end)

    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :host)
    assert {:ok, client} = Incus.connect(connection, context)
    assert client.server.environment == nil
    assert client.server.raw["new_field"] == 7
    assert Incus.has_extension?(client, "projects")

    assert {:error, %Error{kind: :unsupported_extension, extension: "missing"}} =
             Incus.require_extension(client, "missing")

    assert length(HTTPFixture.requests(fixture)) == 1
  end

  test "readiness/owner selection cannot dispatch and explicit connections stay isolated", %{
    root: root,
    context: context
  } do
    fixture = backend(root, fn _ -> reply(nil) end)

    connection =
      Connection.unix!(HTTPFixture.endpoint(fixture).socket,
        owner: :host,
        project: "one",
        member: "node/a"
      )

    delayed = %{context | ready?: fn -> false end}

    assert {:error, %Error{kind: :host_not_ready}} =
             Incus.raw_query(connection, delayed, "GET", "/1.0", [])

    assert {:error, %Error{kind: :owner_mismatch}} =
             Incus.raw_query(connection, %{context | owner: :other}, "GET", "/1.0", [])

    assert {:error, %Error{kind: :selection_mismatch}} =
             Incus.raw_query(connection, context, "GET", "/1.0?project=other", [])

    assert HTTPFixture.requests(fixture) == []
    assert {:ok, _} = Incus.raw_query(connection, context, "GET", "/1.0", [])

    assert {:ok, _} =
             Incus.raw_query(Connection.project(connection, "two"), context, "GET", "/1.0", [])

    assert [first, second] = HTTPFixture.requests(fixture)

    assert URI.decode_query(URI.parse(first.target).query) == %{
             "project" => "one",
             "target" => "node/a"
           }

    assert URI.decode_query(URI.parse(second.target).query) == %{
             "project" => "two",
             "target" => "node/a"
           }
  end

  test "unknown versions and malformed native envelopes cannot be mistaken for success", %{
    root: root,
    context: context
  } do
    fixture = backend(root, fn _ -> reply(%{"api_version" => "2.0", "api_extensions" => []}) end)
    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :host)
    assert {:error, %Error{kind: :unsupported_version}} = Incus.connect(connection, context)

    malformed =
      backend(root, fn _ -> %{status: 200, body: %{"type" => "unknown", "metadata" => nil}} end)

    connection = Connection.unix!(HTTPFixture.endpoint(malformed).socket, owner: :host)

    assert {:error, %Error{kind: :invalid_envelope}} =
             Incus.raw_query(connection, context, "GET", "/1.0", [])

    assert {:error, %Error{kind: :uncertain}} =
             Incus.raw_query(connection, context, "PUT", "/1.0/profiles/a", body: %{})
  end

  test "native error values, conditional ETags and operation acceptance remain distinct", %{
    root: root,
    context: context
  } do
    fixture =
      backend(root, fn request ->
        if request.headers["if-match"] == "stale" do
          %{
            status: 412,
            headers: %{"ETag" => "ignored"},
            body: %{
              "type" => "error",
              "error_code" => 412,
              "error" => "native conflict",
              "metadata" => nil
            }
          }
        else
          %{
            status: 202,
            headers: %{"ETag" => "native"},
            body: %{
              "type" => "async",
              "status_code" => 100,
              "operation" => "/1.0/operations/native-id",
              "metadata" => %{"id" => "native-id", "status_code" => 103}
            }
          }
        end
      end)

    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :host)

    assert {:error,
            %Error{
              kind: :native,
              error_code: 412,
              http_status: 412,
              message: "native conflict",
              response: response
            }} =
             Incus.raw_query(connection, context, "PUT", "/1.0/profiles/a",
               body: %{},
               etag: "stale"
             )

    assert response.metadata == nil

    assert {:ok, accepted} =
             Incus.raw_query(connection, context, "POST", "/1.0/instances",
               body: %{"name" => "fixture"}
             )

    assert Response.accepted?(accepted)
    assert accepted.operation == "/1.0/operations/native-id"
    assert accepted.etag == "native"
    refute accepted.status_code == 200
  end

  test "lost mutation response is uncertain and never retried; bounded reads release connections",
       %{root: root, context: context} do
    fixture = backend(root, fn _ -> %{raw: ""} end)

    connection =
      Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :host, timeout: 100)

    assert {:error, %Error{kind: :uncertain}} =
             Incus.raw_query(connection, context, "POST", "/1.0/instances", body: %{})

    assert length(HTTPFixture.requests(fixture)) == 1

    assert {:error, %Error{kind: :response}} =
             Incus.raw_query(connection, context, "GET", "/1.0", [])

    assert length(HTTPFixture.requests(fixture)) == 2
  end

  test "response/request and total deadline bounds fail visibly", %{root: root, context: context} do
    fixture = backend(root, fn _ -> reply(String.duplicate("x", 100)) end)

    connection =
      Connection.unix!(HTTPFixture.endpoint(fixture).socket,
        owner: :host,
        max_response_bytes: 32,
        max_request_bytes: 32
      )

    assert {:error, %Error{kind: :invalid_body}} =
             Incus.raw_query(connection, context, "PUT", "/1.0/profiles/a",
               body: %{"v" => String.duplicate("x", 100)}
             )

    assert HTTPFixture.requests(fixture) == []

    assert {:error, %Error{kind: :response_limit}} =
             Incus.raw_query(connection, context, "GET", "/1.0", [])

    slow =
      backend(root, fn _ ->
        %{wire_chunks: [{200, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"}]}
      end)

    connection = Connection.unix!(HTTPFixture.endpoint(slow).socket, owner: :host, timeout: 30)
    before = System.monotonic_time(:millisecond)
    assert {:error, %Error{kind: kind}} = Incus.raw_query(connection, context, "GET", "/1.0", [])
    assert kind in [:response, :deadline]
    assert System.monotonic_time(:millisecond) - before < 150
  end

  test "HTTPS verifies trust, hostname and client key possession without credential output", %{
    root: root,
    context: context
  } do
    server = TLSIdentity.generate(root, "server", "localhost")
    client = TLSIdentity.generate(root, "client", "client")
    bad = TLSIdentity.generate(root, "bad", "wrong-host")

    fixture =
      start_supervised!(
        {HTTPFixture,
         [
           transport: :ssl,
           certfile: server.certfile,
           keyfile: server.keyfile,
           peer_options: [
             verify: :verify_peer,
             fail_if_no_peer_cert: true,
             cacertfile: String.to_charlist(client.cafile)
           ],
           handler: fn _ -> reply(nil) end
         ]}
      )

    connection =
      Connection.https!(HTTPFixture.endpoint(fixture).url,
        owner: :host,
        tls: [cacertfile: server.cafile, certfile: client.certfile, keyfile: client.keyfile]
      )

    assert {:ok, _} = Incus.raw_query(connection, context, "GET", "/1.0", [])

    for tls <- [
          Keyword.put(connection.tls, :cacertfile, bad.cafile),
          Keyword.put(connection.tls, :keyfile, bad.keyfile),
          Keyword.put(connection.tls, :certfile, bad.certfile)
        ] do
      assert {:error, error} =
               Incus.raw_query(%{connection | tls: tls}, context, "GET", "/1.0", [])

      refute inspect(error) =~ root
      refute inspect(error) =~ "BEGIN"
    end

    wrong_name = %{connection | address: %{connection.address | host: "127.0.0.1"}}
    assert {:error, _} = Incus.raw_query(wrong_name, context, "GET", "/1.0", [])
    assert length(HTTPFixture.requests(fixture)) == 1
  end

  defp backend(root, handler) do
    start_supervised!(
      {HTTPFixture,
       transport: :gen_tcp,
       path: Path.join(root, "sock-#{System.unique_integer([:positive])}"),
       handler: handler},
      id: make_ref()
    )
  end

  defp reply(metadata),
    do: %{
      status: 200,
      body: %{
        "type" => "sync",
        "status" => "Success",
        "status_code" => 200,
        "metadata" => metadata
      }
    }
end
