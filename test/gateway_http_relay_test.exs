defmodule Opsmaru.Incus.GatewayHTTPRelayTest.SlowChunkAdapter do
  # Plug adapter whose chunk delivery is slow, so the relay is busy while
  # backend data waits in its mailbox.
  def send_chunked(state, _status, _headers), do: {:ok, nil, state}

  def chunk(state, data) do
    Process.sleep(state.delay)
    send(state.observer, {:chunk, IO.iodata_to_binary(data)})
    :ok
  end

  def send_resp(state, _status, _headers, _body), do: {:ok, nil, state}
end

defmodule Opsmaru.Incus.GatewayHTTPRelayTest do
  # Tasks 3.1-3.3: streamed native HTTP relay over Unix and verified HTTPS,
  # bounded binary transfers and framing guards, and truthful failures.
  use Opsmaru.TestSupport.GatewayCase, async: true

  # Aborting a committed HTTP/1.1 response ends its Cowboy connection process,
  # which Ranch logs as an error.
  @moduletag :capture_log

  alias Opsmaru.Incus.Gateway.{HTTPRelay, Policy, Request}
  alias Opsmaru.Incus.GatewayHTTPRelayTest.SlowChunkAdapter
  alias Opsmaru.TestSupport.TLSIdentity

  @operation "/1.0/operations/3c1a8a6e-7a0e-4f5b-9a55-6a2f1a7e0c11"

  describe "native fidelity (3.1)" do
    test "statuses, native errors, ETags and operation identity pass unchanged over Unix",
         context do
      body = %{
        "type" => "async",
        "status" => "Operation created",
        "status_code" => 100,
        "operation" => @operation,
        "metadata" => %{"id" => "3c1a8a6e", "class" => "task"}
      }

      {_, connection} =
        backend(context, reply(202, body, [{"location", @operation}, {"etag", ~s("abc123")}]))

      mount(context, connection)

      response =
        RawHTTP.request(
          context.port,
          "POST",
          "/1.0/instances?project=allowed",
          [auth(), {"content-type", "application/json"}],
          ~s({"name":"c1","source":{"type":"none"}})
        )

      assert response.status == 202
      assert native(response.body) == body
      assert RawHTTP.header(response, "location") == [@operation]
      assert RawHTTP.header(response, "etag") == [~s("abc123")]

      assert_receive {:backend_request,
                      %{method: "POST", target: "/1.0/instances?project=allowed"}}
    end

    test "native backend errors are not rewritten", context do
      error = %{
        "type" => "error",
        "status" => "",
        "status_code" => 0,
        "operation" => "",
        "error_code" => 412,
        "error" => "ETag doesn't match",
        "metadata" => nil
      }

      {_, connection} = backend(context, reply(412, error))
      mount(context, connection)

      response =
        RawHTTP.request(
          context.port,
          "PUT",
          "/1.0/instances/c1",
          [auth(), {"if-match", ~s("stale")}],
          ~s({"config":{}})
        )

      assert {response.status, native(response.body)} == {412, error}
      assert_receive {:backend_request, %{headers: headers}}
      assert {"if-match", ~s("stale")} in headers
    end

    test "unknown methods and routes pass through without a typed catalogue", context do
      {_, connection} = backend(context, reply(200, %{"type" => "sync", "metadata" => "ok"}))
      mount(context, connection)

      response =
        RawHTTP.request(context.port, "PATCH", "/1.0/future-extension/x", [auth()], "{}")

      assert response.status == 200
      assert_receive {:backend_request, %{method: "PATCH", target: "/1.0/future-extension/x"}}
    end

    test "credentials, proxy identity and hop-by-hop fields stay at the gateway", context do
      {_, connection} = backend(context, reply(200, %{}))
      mount(context, connection)

      get(context, "/1.0/instances", [
        auth(),
        {"cookie", "session=private"},
        {"proxy-authorization", "Basic cHJpdmF0ZQ=="},
        {"x-forwarded-for", "203.0.113.9"},
        {"x-forwarded-host", "evil.example"},
        {"forwarded", "for=203.0.113.9"},
        {"x-real-ip", "203.0.113.9"},
        {"connection", "keep-alive, x-hop"},
        {"keep-alive", "timeout=5"},
        {"x-hop", "dropped"},
        {"te", "trailers"},
        {"user-agent", "Incus 7.0.1"},
        {"x-incus-authenticated", "true"},
        {"accept", "application/json"}
      ])

      assert_receive {:backend_request, %{headers: headers}}
      names = Enum.map(headers, &elem(&1, 0))

      for name <-
            ~w(authorization cookie proxy-authorization x-forwarded-for x-forwarded-host forwarded x-real-ip keep-alive x-hop te),
          do: refute(name in names, name)

      # The backend connection sets the host, as the typed client does.
      assert {"host", "unix.socket:0"} in headers
      assert {"user-agent", "Incus 7.0.1"} in headers
      assert {"x-incus-authenticated", "true"} in headers
      assert {"accept", "application/json"} in headers
    end

    test "end-to-end response fields survive; hop-by-hop response fields do not", context do
      response = [
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\n",
        "x-incus-a: 1\r\nx-incus-a: 2\r\nconnection: close, x-private\r\nx-private: dropped\r\n",
        "keep-alive: timeout=1\r\n\r\n{}"
      ]

      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)
          StreamBackend.write(conn, response)
        end)

      mount(context, connection)
      result = get(context, "/1.0/instances")
      assert result.status == 200
      # Cowboy writes repeated fields as one comma-joined field (RFC 9110 5.3).
      assert RawHTTP.header(result, "x-incus-a") == ["1, 2"]
      assert RawHTTP.header(result, "x-private") == []
      assert RawHTTP.header(result, "keep-alive") == []
    end

    test "HEAD and bodyless statuses keep their framing", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)

          case conn.head do
            %{method: "HEAD"} ->
              StreamBackend.write(
                conn,
                "HTTP/1.1 200 OK\r\ncontent-length: 1234\r\netag: \"h\"\r\n\r\n"
              )

            %{target: "/1.0/no-content"} ->
              StreamBackend.write(conn, "HTTP/1.1 204 No Content\r\netag: \"n\"\r\n\r\n")

            _ ->
              StreamBackend.write(conn, "HTTP/1.1 304 Not Modified\r\netag: \"m\"\r\n\r\n")
          end
        end)

      mount(context, connection)
      head = RawHTTP.request(context.port, "HEAD", "/1.0/instances/c1/files?path=%2Fx", [auth()])
      assert {head.status, head.body} == {200, ""}
      assert RawHTTP.header(head, "content-length") == ["1234"]
      assert RawHTTP.header(head, "etag") == [~s("h")]

      for {target, status, etag} <- [
            {"/1.0/no-content", 204, ~s("n")},
            {"/1.0/cached", 304, ~s("m")}
          ] do
        response = get(context, target)
        assert {response.status, response.body} == {status, ""}
        assert RawHTTP.header(response, "etag") == [etag]
        assert RawHTTP.header(response, "transfer-encoding") == []
      end
    end

    test "every exchange uses its own backend connection", context do
      {backend, connection} =
        backend(context, fn conn ->
          Process.sleep(100)
          StreamBackend.write(conn, StreamBackend.json(200, %{"n" => 1}))
        end)

      mount(context, connection)

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> get(context, "/1.0/instances") end) end)
        |> Task.await_many(5_000)

      assert Enum.all?(results, &(&1.status == 200))
      assert StreamBackend.accepted(backend) == 4
    end
  end

  describe "verified HTTPS backends (3.1)" do
    setup context do
      server = TLSIdentity.generate(context.root, "backend", "localhost")
      client = TLSIdentity.generate(context.root, "gateway", "gateway-client")
      other = TLSIdentity.generate(context.root, "other", "localhost")
      %{server: server, client: client, other: other}
    end

    defp https_backend(context, server, script) do
      pid =
        start_supervised!(
          {StreamBackend,
           tls: server, client_ca: context.client.cafile, observer: self(), script: script},
          id: make_ref()
        )

      {pid, "https://localhost:#{StreamBackend.port(pid)}"}
    end

    defp https_connection(url, ca, client) do
      Connection.https!(url,
        owner: :fixture,
        tls: [cacertfile: ca, certfile: client.certfile, keyfile: client.keyfile]
      )
    end

    test "relays with mutual TLS and the gateway's own client identity", context do
      {_, url} = https_backend(context, context.server, reply(200, %{"type" => "sync"}))
      mount(context, https_connection(url, context.server.cafile, context.client))
      response = get(context, "/1.0/instances?project=allowed")
      assert response.status == 200

      assert_receive {:backend_request,
                      %{target: "/1.0/instances?project=allowed", headers: headers}}

      refute List.keymember?(headers, "authorization", 0)
    end

    test "wrong upstream trust or keys fail before any request is sent", context do
      {backend, url} = https_backend(context, context.other, reply(200, %{}))
      mount(context, https_connection(url, context.server.cafile, context.client))
      response = get(context, "/1.0/instances")
      assert response.status == 502
      assert native(response.body)["metadata"]["gateway"]["outcome"] == "not_sent"
      refute_receive {:backend_request, _}, 100

      # A client identity the backend does not trust.
      {_, url} = https_backend(context, context.server, reply(200, %{}))
      mount(context, https_connection(url, context.server.cafile, context.other))
      assert get(context, "/1.0/instances").status == 502
      refute_receive {:backend_request, _}, 100
      assert StreamBackend.accepted(backend) <= 1
    end
  end

  describe "binary transfers and framing (3.2)" do
    test "large sized and chunked uploads stream byte-for-byte", context do
      parent = self()

      {_, connection} =
        backend(context, fn conn ->
          {conn, hash, size} = StreamBackend.read_body(conn)
          send(parent, {:uploaded, hash, size})
          StreamBackend.write(conn, StreamBackend.json(200, %{"size" => size}))
        end)

      mount(context, connection, max_chunk_bytes: 16_384)
      payload = :crypto.strong_rand_bytes(3 * 1_048_576 + 17)

      sized =
        RawHTTP.request(
          context.port,
          "POST",
          "/1.0/instances/c1/files?path=%2Froot%2Fblob",
          [auth(), {"content-type", "application/octet-stream"}],
          payload
        )

      assert sized.status == 200
      assert_receive {:uploaded, hash, size}
      assert {hash, size} == {:crypto.hash(:sha256, payload), byte_size(payload)}
      assert_receive {:backend_request, %{headers: headers}}
      assert {"content-length", Integer.to_string(byte_size(payload))} in headers

      client = RawHTTP.connect(context.port)

      RawHTTP.send!(
        client,
        RawHTTP.head("POST", "/1.0/images", [
          auth(),
          {"transfer-encoding", "chunked"},
          {"connection", "close"}
        ])
      )

      for <<part::binary-size(65_536) <- binary_part(payload, 0, 3 * 1_048_576)>> do
        RawHTTP.send!(client, [Integer.to_string(65_536, 16), "\r\n", part, "\r\n"])
      end

      RawHTTP.send!(client, "0\r\n\r\n")
      assert RawHTTP.read(client, "POST").status == 200
      assert_receive {:uploaded, hash, size}

      assert {hash, size} ==
               {:crypto.hash(:sha256, binary_part(payload, 0, 3 * 1_048_576)), 3 * 1_048_576}

      assert_receive {:backend_request, %{headers: headers}}
      assert {"transfer-encoding", "chunked"} in headers
    end

    test "large sized and chunked downloads stream byte-for-byte", context do
      payload = :crypto.strong_rand_bytes(5 * 1_048_576 + 3)

      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)

          if conn.head.target =~ "chunked" do
            StreamBackend.write(conn, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")

            for <<part::binary-size(1_048_576) <- binary_part(payload, 0, 5 * 1_048_576)>>,
              do:
                StreamBackend.write(conn, [Integer.to_string(1_048_576, 16), "\r\n", part, "\r\n"])

            StreamBackend.write(
              conn,
              "3\r\n" <> binary_part(payload, 5 * 1_048_576, 3) <> "\r\n0\r\n\r\n"
            )
          else
            StreamBackend.write(conn, [
              "HTTP/1.1 200 OK\r\ncontent-type: application/octet-stream\r\n",
              "x-incus-type: file\r\ncontent-length: #{byte_size(payload)}\r\n\r\n",
              payload
            ])
          end
        end)

      mount(context, connection)

      for target <- [
            "/1.0/instances/c1/files?path=%2Fblob",
            "/1.0/instances/c1/backups/b/export?chunked"
          ] do
        response = get(context, target)
        assert response.status == 200
        assert response.complete
        assert :crypto.hash(:sha256, response.body) == :crypto.hash(:sha256, payload)
      end
    end

    test "a slow caller applies backpressure to the backend", context do
      parent = self()
      chunk = :binary.copy(<<7>>, 65_536)
      total = 512

      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)

          StreamBackend.write(
            conn,
            "HTTP/1.1 200 OK\r\ncontent-length: #{total * byte_size(chunk)}\r\n\r\n"
          )

          for n <- 1..total do
            :ok = StreamBackend.write(conn, chunk)
            send(parent, {:written, n})
          end
        end)

      mount(context, connection)
      client = RawHTTP.connect(context.port)

      RawHTTP.send!(
        client,
        RawHTTP.head("GET", "/1.0/instances/c1/files?path=%2Fbig", [
          auth(),
          {"connection", "close"}
        ])
      )

      # The caller reads nothing: the backend must block well short of 32 MiB.
      Process.sleep(1_000)
      written = drain_written(0)
      assert written < total
      response = RawHTTP.read(client)
      assert response.complete
      assert byte_size(response.body) == total * byte_size(chunk)
    end

    test "trailers are forwarded when the caller accepts them", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)

          StreamBackend.write(conn, [
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ntrailer: x-checksum\r\n\r\n",
            "4\r\ndata\r\n0\r\nx-checksum: abcd\r\ncontent-length: 99\r\n\r\n"
          ])
        end)

      mount(context, connection)
      with_te = get(context, "/1.0/instances/c1/logs/x", [auth(), {"te", "trailers"}])
      assert {with_te.body, with_te.complete} == {"data", true}
      assert with_te.trailers == [{"x-checksum", "abcd"}]

      without = get(context, "/1.0/instances/c1/logs/x")
      assert {without.body, without.complete, without.trailers} == {"data", true, []}
    end

    test "oversized requests are refused before the backend", context do
      {backend, connection} = backend(context, reply(200, %{}))
      mount(context, connection, max_request_bytes: 1_024, max_header_bytes: 2_048)

      response =
        RawHTTP.request(context.port, "POST", "/1.0/images", [auth()], :binary.copy("x", 2_048))

      assert response.status == 413
      assert native(response.body)["metadata"]["gateway"]["outcome"] == "not_sent"

      response = get(context, "/1.0/instances", [auth(), {"x-large", :binary.copy("y", 4_096)}])
      assert response.status == 431
      assert StreamBackend.accepted(backend) == 0
    end

    test "a chunked upload over budget stops and reports an uncertain mutation", context do
      parent = self()

      {backend, connection} =
        backend(context, fn conn ->
          send(parent, {:backend_closed_with, StreamBackend.await_close(conn)})
        end)

      mount(context, connection, max_request_bytes: 100_000, max_chunk_bytes: 16_384)
      client = RawHTTP.connect(context.port)

      RawHTTP.send!(
        client,
        RawHTTP.head("POST", "/1.0/images", [
          auth(),
          {"transfer-encoding", "chunked"},
          {"connection", "close"}
        ])
      )

      for _ <- 1..4, do: RawHTTP.send!(client, ["8000\r\n", :binary.copy("z", 32_768), "\r\n"])
      RawHTTP.send!(client, "0\r\n\r\n")
      response = RawHTTP.read(client, "POST")
      assert response.status == 413
      assert native(response.body)["metadata"]["gateway"]["outcome"] == "uncertain"
      # Accept accounting is asynchronous; wait for backend processing first.
      assert_receive {:backend_closed_with, :closed}, 2_000
      assert StreamBackend.accepted(backend) == 1
    end

    test "ambiguous request framing is rejected before the backend", context do
      {backend, connection} = backend(context, reply(200, %{}))
      mount(context, connection)
      client = RawHTTP.connect(context.port)

      RawHTTP.send!(
        client,
        "POST /1.0/images HTTP/1.1\r\nhost: localhost\r\nauthorization: Bearer fixture-token\r\ncontent-length: 3\r\ncontent-length: 4\r\nconnection: close\r\n\r\nabcd"
      )

      response = RawHTTP.read(client)
      assert response.status == 400
      assert StreamBackend.accepted(backend) == 0
    end

    test "invalid backend framing and unsafe response fields fail before commit", context do
      cases = [
        "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ntransfer-encoding: chunked\r\n\r\n{}",
        "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nx-bad: a\x01b\r\n\r\n{}",
        "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nbad header: x\r\n\r\n{}",
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: sftp\r\n\r\n",
        "not http at all\r\n\r\n"
      ]

      for bytes <- cases do
        {_, connection} =
          backend(context, fn conn ->
            {conn, _, _} = StreamBackend.read_body(conn)
            StreamBackend.write(conn, bytes)
          end)

        mount(context, connection)
        response = get(context, "/1.0/instances")
        assert response.status == 502, bytes
        assert native(response.body)["metadata"]["gateway"]["outcome"] == "sent"
        refute RawHTTP.header(response, "x-bad") != []
      end
    end

    test "a caller that disconnects mid-download releases the backend and admission",
         context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)
          StreamBackend.write(conn, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
          stream_until_closed(conn)
        end)

      mount(context, connection)
      {:gen_tcp, socket} = client = RawHTTP.connect(context.port)
      RawHTTP.send!(client, RawHTTP.head("GET", "/1.0/events", [auth()]))
      {:ok, _} = :gen_tcp.recv(socket, 0, 2_000)
      assert Admission.count(context.admission) == 1
      :gen_tcp.close(socket)
      assert_receive {:backend_closed, _}, 3_000
      wait_until(fn -> Admission.count(context.admission) == 0 end)
    end
  end

  describe "truthful failure (3.3)" do
    test "a mutation whose response is lost is reported uncertain and sent once", context do
      {backend, connection} =
        backend(context, fn conn ->
          {_conn, _, _} = StreamBackend.read_body(conn)
        end)

      mount(context, connection)

      response =
        RawHTTP.request(context.port, "POST", "/1.0/instances", [auth()], ~s({"name":"c1"}))

      assert response.status == 502
      assert native(response.body)["metadata"]["gateway"]["outcome"] == "uncertain"
      assert_received {:backend_request, %{method: "POST"}}
      refute_receive {:backend_request, _}, 200
      assert StreamBackend.accepted(backend) == 1
    end

    test "a read whose response is lost is reported as sent, not uncertain", context do
      {_, connection} = backend(context, fn conn -> StreamBackend.read_body(conn) end)
      mount(context, connection)
      response = get(context, "/1.0/instances")
      assert response.status == 502
      assert native(response.body)["metadata"]["gateway"]["outcome"] == "sent"
    end

    test "a silent backend hits the idle deadline without a retry", context do
      {backend, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)
          StreamBackend.await_close(conn, 5_000)
        end)

      mount(context, connection, idle_timeout: 200)

      {elapsed, response} =
        :timer.tc(
          fn ->
            RawHTTP.request(context.port, "DELETE", "/1.0/instances/c1", [auth()])
          end,
          :millisecond
        )

      assert response.status == 504
      assert native(response.body)["metadata"]["gateway"]["outcome"] == "uncertain"
      assert elapsed < 2_000
      assert StreamBackend.accepted(backend) == 1
      assert_receive {:backend_closed, _}, 2_000
    end

    test "redirects are relayed, never followed", context do
      {backend, connection} =
        backend(context, reply(307, %{}, [{"location", "https://other.example/1.0/instances"}]))

      mount(context, connection)
      response = RawHTTP.request(context.port, "POST", "/1.0/instances", [auth()], "{}")
      assert response.status == 307
      assert RawHTTP.header(response, "location") == ["https://other.example/1.0/instances"]
      assert StreamBackend.accepted(backend) == 1
    end

    test "a known operation identity is kept when an accepted response is unusable", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)

          StreamBackend.write(
            conn,
            "HTTP/1.1 101 Switching Protocols\r\nlocation: #{@operation}\r\nupgrade: nbd\r\nconnection: upgrade\r\n\r\n"
          )
        end)

      mount(context, connection)
      response = RawHTTP.request(context.port, "POST", "/1.0/instances", [auth()], "{}")
      assert response.status == 502
      gateway = native(response.body)["metadata"]["gateway"]
      assert gateway == %{"outcome" => "uncertain", "operation" => @operation}
    end

    test "a committed chunked response cut short is visibly incomplete", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)

          StreamBackend.write(
            conn,
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n"
          )
        end)

      mount(context, connection)
      response = get(context, "/1.0/instances/c1/backups/b/export")
      assert response.status == 200
      assert response.body == "hello"
      refute response.complete
    end

    test "a committed sized response cut short is visibly incomplete", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)
          StreamBackend.write(conn, "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nhello")
        end)

      mount(context, connection)
      response = get(context, "/1.0/instances/c1/files?path=%2Fx")
      assert response.status == 200
      refute response.complete
    end

    test "a response over its byte budget is cut short, not completed", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)
          StreamBackend.write(conn, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")

          for _ <- 1..64,
              do: StreamBackend.write(conn, ["400\r\n", :binary.copy("q", 1_024), "\r\n"])

          StreamBackend.write(conn, "0\r\n\r\n")
        end)

      mount(context, connection, max_response_bytes: 8_192)
      response = get(context, "/1.0/instances/c1/backups/b/export")
      assert response.status == 200
      refute response.complete
      assert byte_size(response.body) <= 8_192
    end

    test "stopping admission ends an active exchange without a backend retry", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)
          StreamBackend.await_close(conn, 10_000)
        end)

      mount(context, connection)
      task = Task.async(fn -> get(context, "/1.0/operations/x/wait") end)
      assert_receive {:backend_request, _}, 2_000
      stop_supervised!(Admission)
      response = Task.await(task, 5_000)
      assert response.status == 503
      assert native(response.body)["metadata"]["gateway"]["outcome"] == "sent"
      assert_receive {:backend_closed, _}, 2_000
    end

    test "admission stopped during authorization sends nothing to the backend", context do
      {backend, connection} = backend(context, reply(200, %{"type" => "sync"}))
      admission = context.admission

      # The slot disappears while the host decides; a bodyless DELETE would
      # otherwise be sent whole by the first backend write.
      mount(context, connection,
        host_config: %{
          authorize: fn _request ->
            ref = Process.monitor(admission)
            Process.exit(admission, :kill)
            assert_receive {:DOWN, ^ref, :process, _, _}
            {:ok, :fixture_grant}
          end
        }
      )

      response = RawHTTP.request(context.port, "DELETE", "/1.0/instances/c1", [auth()])
      assert response.status == 503
      assert native(response.body)["metadata"]["gateway"]["outcome"] == "not_sent"
      assert StreamBackend.accepted(backend) == 0
    end

    test "a busy download is ended at its lifetime even with backend data queued", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)

          # The whole response is queued at the gateway before the deadline.
          StreamBackend.write(
            conn,
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n" <>
              "5\r\nfirst\r\n6\r\nsecond\r\n0\r\n\r\n"
          )

          StreamBackend.await_close(conn)
        end)

      gateway = mount(context, connection, max_lifetime: 300)
      {:ok, slot} = Admission.acquire(context.admission)
      admitted = %Policy.Admitted{slot: slot, admission: elem(slot, 0), grant: :fixture_grant}
      path = "/1.0/instances/c1/logs/console.log"
      request = %Request{protocol: :http, method: "GET", path: path, query: "", peer: %{}}

      # Delivering the first chunk outlasts the lifetime, as a slow caller would.
      conn = %{
        Plug.Test.conn(:get, path)
        | adapter: {SlowChunkAdapter, %{observer: self(), delay: 600}}
      }

      assert catch_exit(HTTPRelay.relay(conn, gateway, request, admitted)) ==
               :gateway_stream_aborted

      assert_received {:chunk, "first"}
      refute_received {:chunk, "second"}
      assert_receive {:backend_closed, _}, 2_000
    end
  end

  defp drain_written(last) do
    receive do
      {:written, n} -> drain_written(n)
    after
      0 -> last
    end
  end

  defp stream_until_closed(conn) do
    case StreamBackend.write(conn, "5\r\nevent\r\n") do
      :ok ->
        Process.sleep(20)
        stream_until_closed(conn)

      _ ->
        :ok
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end
