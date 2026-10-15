defmodule Opsmaru.Incus.InstancePatchTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Operation, RequestContext, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}
  @driver Path.expand("../.integration/instance-patch-driver", __DIR__)
  @body %{
    "description" => "",
    "ephemeral" => false,
    "profiles" => [],
    "config" => %{},
    "devices" => %{}
  }

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-patch-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} typed PATCH preserves field presence, routing, If-Match and native errors",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for body <- [
            %{},
            @body,
            %{"description" => nil, "config" => nil},
            %{"config" => %{"user.note" => "fixture"}, "future_field" => false}
          ],
          do: compare(root, identity, body, 200)

      for code <- [400, 403, 404, 412], do: compare(root, identity, %{"restore" => "snap"}, code)
    end

    test "#{transport} dispatched PATCH failures stay uncertain without replay or invented identity",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for reply <- [
            %{upgrade: fn _, _ -> :ok end},
            %{status: 200, body: "malformed"},
            %{status: 200, body: %{type: "sync", status_code: 200, metadata: nil}},
            %{
              status: 202,
              body: %{
                type: "async",
                status_code: 100,
                operation: "/1.0/operations/received",
                metadata: %{id: "received"}
              }
            }
          ] do
        fixture = backend(root, identity, fn _ -> reply end)

        assert {:error, %Error{kind: :uncertain} = error} =
                 patch(client(fixture, identity), @body)

        if reply[:status] == 202 do
          assert error.operation == "/1.0/operations/received"
          assert error.response.type == "async"
        else
          assert error.operation in [nil, ""]
        end

        assert [%{method: "PATCH"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{transport} dispatched PATCH deadline and cancellation close the peer and remain uncertain",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for mode <- [:deadline, :cancel] do
        parent = self()
        tag = make_ref()

        fixture =
          backend(root, identity, fn _ ->
            %{
              upgrade: fn transport, socket ->
                send(parent, {tag, :entered})
                send(parent, {tag, :closed, transport.recv(socket, 0, 30_000)})
              end
            }
          end)

        original = client(fixture, identity)
        scope = RequestContext.new!(timeout: if(mode == :deadline, do: 3_000, else: 30_000))
        scoped = Incus.with_context(original, scope)
        task = Task.async(fn -> patch(scoped, @body) end)
        assert_receive {^tag, :entered}, 10_000
        if mode == :cancel, do: RequestContext.cancel(scope)
        assert {:error, %Error{kind: :uncertain, operation: nil}} = Task.await(task, 10_000)
        assert_receive {^tag, :closed, {:error, :closed}}, 10_000
        assert original.connection.request_context == nil
        assert [%{method: "PATCH"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{transport} conditional PATCH preflight rejects invalid input without I/O", %{
      root: root
    } do
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> response(200) end)
      client = client(fixture, identity)

      for {args, opts} <- [
            {%{"name" => "guest"}, [body: @body]},
            {%{"name" => "guest"}, [body: @body, etag: ""]},
            {%{"name" => "guest"}, [body: @body, etag: String.duplicate("e", 1025)]},
            {%{"name" => "guest"}, [body: @body, etag: "first", etag: "second"]},
            {%{"name" => ""}, [body: @body, etag: "before"]},
            {%{"name" => "guest"}, [body: %{"ephemeral" => "false"}, etag: "before"]},
            {%{"name" => "guest"}, [body: @body, etag: "before\r\nInjected: true"]}
          ] do
        assert {:error, %Error{kind: kind}} = Incus.call(client, "PatchInstance", args, opts)
        refute kind == :uncertain
      end

      small = %{client | connection: %{client.connection | max_request_bytes: 16}}
      assert {:error, %Error{kind: :invalid_body}} = patch(small, @body)
      unready = %{client | context: %{client.context | ready?: fn -> false end}}
      assert {:error, %Error{kind: :host_not_ready}} = patch(unready, @body)
      assert HTTPFixture.requests(fixture) == []
    end
  end

  defp compare(root, identity, body, code) do
    fixture = backend(root, identity, fn _ -> response(code) end)
    client = client(fixture, identity)

    input =
      Map.merge(native_connection(fixture, identity), %{
        action: "RawQuery",
        args: [
          "PATCH",
          "/1.0/instances/guest?project=fixture+scope&target=member%2Fa",
          body,
          "\"before\""
        ]
      })

    file = Path.join(root, "oracle.json")
    File.write!(file, Jason.encode!(input))
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    expected = Jason.decode!(out)
    actual = patch(client, body)
    assert [%{method: "GET"}, native, local] = HTTPFixture.requests(fixture)
    assert native.method == "PATCH"
    assert Jason.decode!(local.body) == body
    assert local.headers["if-match"] == "\"before\""

    assert URI.decode_query(URI.parse(local.target).query) == %{
             "project" => "fixture scope",
             "target" => "member/a"
           }

    assert WireComparison.request(native) == WireComparison.request(local)

    if code == 200 do
      refute expected["error"]
      assert {:ok, reply} = actual
      assert reply.http_status == 200 and reply.type == "sync" and reply.metadata == %{}
      assert reply.operation == ""
      assert reply.etag == Enum.at(expected["outputs"], 1)
      assert hd(expected["outputs"])["metadata"] == reply.metadata
      assert reply.connection == client.connection and reply.identity == :verified

      assert {:error, %Error{kind: :invalid_operation_binding}} =
               Operation.from_response(client, reply)
    else
      assert {:error,
              %Error{kind: :native, http_status: ^code, error_code: ^code, message: message}} =
               actual

      assert expected["error"] == message and expected["error_status"] == code
    end
  end

  defp patch(client, body),
    do: Incus.call(client, "PatchInstance", %{"name" => "guest"}, body: body, etag: "\"before\"")

  defp response(200),
    do: %{
      status: 200,
      headers: %{"ETag" => "\"after\""},
      body: %{type: "sync", status_code: 200, metadata: %{}}
    }

  defp response(400),
    do: %{
      status: 400,
      body: %{type: "error", error_code: 400, error: "Can't call PATCH in restore mode"}
    }

  defp response(code),
    do: %{status: code, body: %{type: "error", error_code: code, error: "native rejection"}}

  defp identity(_, :unix), do: nil
  defp identity(root, :https), do: TLSIdentity.generate(root, "patch", "localhost")

  defp backend(root, identity, handler) do
    options =
      if identity,
        do: [
          transport: :ssl,
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            cacertfile: identity.cafile,
            verify: :verify_peer,
            fail_if_no_peer_cert: true
          ]
        ],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "s#{System.unique_integer([:positive])}")
        ]

    start_supervised!(
      {HTTPFixture,
       options ++
         [
           handler: fn request ->
             if URI.parse(request.target).path == "/1.0",
               do: %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{api_version: "1.0", api_extensions: [], environment: %{}}
                 }
               },
               else: handler.(request)
           end
         ]},
      id: make_ref()
    )
  end

  defp client(fixture, identity) do
    endpoint = HTTPFixture.endpoint(fixture)
    options = [owner: :fixture, project: "fixture scope", member: "member/a", timeout: 30_000]

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            options ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, options)

    %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: []}
    }
  end

  defp native_connection(fixture, nil), do: %{socket: HTTPFixture.endpoint(fixture).socket}

  defp native_connection(fixture, identity),
    do: %{
      url: HTTPFixture.endpoint(fixture).url,
      tls_ca: File.read!(identity.cafile),
      client_cert: File.read!(identity.certfile),
      client_key: File.read!(identity.keyfile)
    }
end
