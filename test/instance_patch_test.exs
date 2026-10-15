defmodule Opsmaru.Incus.InstancePatchTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Model, Operation, RequestContext, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}
  @driver Path.expand("../.integration/instance-patch-driver", __DIR__)
  @body %{
    "description" => "",
    "ephemeral" => false,
    "profiles" => [],
    "config" => %{},
    "devices" => %{}
  }

  @patches [
    %{
      method: "PatchInstance",
      args: %{"name" => "guest"},
      path: "/1.0/instances/guest",
      body: @body,
      populated: %{
        "config" => %{"user.note" => "fixture"},
        "devices" => %{"data" => %{"type" => "disk", "path" => "/data", "pool" => "fixture"}}
      },
      null: %{"description" => nil, "config" => nil},
      invalid: %{"ephemeral" => "false"},
      rejection: %{"restore" => "snap"},
      extension: nil,
      accepted: false
    },
    %{
      method: "PatchProject",
      args: %{"name" => "project /one"},
      path: "/1.0/projects/project%20%2Fone",
      body: %{"description" => "", "config" => %{}},
      populated: %{"config" => %{"features.images" => "true", "user.note" => "fixture"}},
      null: %{"description" => nil, "config" => nil},
      invalid: %{"description" => false},
      rejection: %{},
      extension: "projects",
      accepted: false
    },
    %{
      method: "PatchProfile",
      args: %{"name" => "profile /one"},
      path: "/1.0/profiles/profile%20%2Fone",
      body: %{"description" => "", "config" => %{}, "devices" => %{}},
      populated: %{
        "config" => %{"user.note" => "fixture"},
        "devices" => %{"data" => %{"type" => "disk", "path" => "/data", "pool" => "fixture"}}
      },
      null: %{"config" => nil, "devices" => nil},
      invalid: %{"devices" => false},
      rejection: %{},
      extension: nil,
      accepted: false
    },
    %{
      method: "PatchImage",
      args: %{"fingerprint" => "image /one"},
      path: "/1.0/images/image%20%2Fone",
      body: %{"public" => false, "auto_update" => false, "properties" => %{}},
      populated: %{
        "public" => false,
        "auto_update" => false,
        "properties" => %{"os" => "Linux", "description" => "fixture"}
      },
      null: %{"properties" => nil},
      invalid: %{"public" => "false"},
      rejection: %{},
      extension: nil,
      accepted: false
    },
    %{
      method: "PatchInstanceSnapshot",
      args: %{"name" => "guest /one", "snapshot" => "snap /one"},
      path: "/1.0/instances/guest%20%2Fone/snapshots/snap%20%2Fone",
      body: %{"expires_at" => "2030-01-02T03:04:05Z"},
      populated: %{"expires_at" => "2030-01-02T03:04:05Z"},
      null: %{"expires_at" => nil},
      invalid: %{"expires_at" => false},
      rejection: %{},
      extension: "snapshot_expiry",
      accepted: true
    }
  ]

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out

    rest =
      Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
      |> Enum.filter(&(&1["reference_kind"] == "rest" and &1["verb"] == "PATCH"))
      |> Enum.map(& &1["name"])

    assert Enum.sort(rest) == Enum.sort(Enum.map(@patches, & &1.method))
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-patch-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for spec <- @patches, transport <- [:unix, :https] do
    test "#{transport} #{spec.method} typed PATCH preserves field presence, routing, If-Match and native errors",
         %{root: root} do
      spec = unquote(Macro.escape(spec))
      identity = identity(root, unquote(transport))

      for body <- [%{}, spec.body, spec.null, Map.put(spec.populated, "future_field", false)],
          do: compare(root, identity, spec, body, 200)

      for code <- [400, 403, 404, 412], do: compare(root, identity, spec, spec.rejection, code)
    end

    test "#{transport} #{spec.method} dispatched PATCH failures stay uncertain without replay or invented identity",
         %{root: root} do
      spec = unquote(Macro.escape(spec))
      identity = identity(root, unquote(transport))

      for reply <- [
            %{upgrade: fn _, _ -> :ok end},
            %{status: 200, body: "malformed"},
            %{status: 200, body: %{type: "sync", status_code: 200, metadata: nil}},
            %{
              status: if(spec.accepted, do: 200, else: 202),
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
                 patch(client(fixture, identity), spec, spec.body)

        if is_map(reply[:body]) and reply.body[:type] == "async" do
          assert error.operation == "/1.0/operations/received"
          assert error.response.type == "async"
        else
          assert error.operation in [nil, ""]
        end

        assert [%{method: "PATCH"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{transport} #{spec.method} dispatched PATCH deadline and cancellation close the peer and remain uncertain",
         %{root: root} do
      spec = unquote(Macro.escape(spec))
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
        task = Task.async(fn -> patch(scoped, spec, spec.body) end)
        assert_receive {^tag, :entered}, 10_000
        if mode == :cancel, do: RequestContext.cancel(scope)
        assert {:error, %Error{kind: :uncertain, operation: nil}} = Task.await(task, 10_000)
        assert_receive {^tag, :closed, {:error, :closed}}, 10_000
        assert original.connection.request_context == nil
        assert [%{method: "PATCH"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{transport} #{spec.method} conditional PATCH preflight rejects invalid input without I/O",
         %{
           root: root
         } do
      spec = unquote(Macro.escape(spec))
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> response(200) end)
      client = client(fixture, identity)

      for {args, opts} <-
            [
              {spec.args, [body: spec.body]},
              {spec.args, [body: spec.body, etag: ""]},
              {spec.args, [body: spec.body, etag: String.duplicate("e", 1025)]},
              {spec.args, [body: spec.body, etag: "first", etag: "second"]},
              {spec.args, [body: spec.invalid, etag: "before"]},
              {spec.args, [body: spec.body, etag: "before\r\nInjected: true"]}
            ] ++
              Enum.map(spec.args, fn {key, _} ->
                {Map.put(spec.args, key, ""), [body: spec.body, etag: "before"]}
              end) do
        assert {:error, %Error{kind: kind}} = Incus.call(client, spec.method, args, opts)
        refute kind == :uncertain
      end

      small = %{client | connection: %{client.connection | max_request_bytes: 16}}
      assert {:error, %Error{kind: :invalid_body}} = patch(small, spec, spec.body)
      unready = %{client | context: %{client.context | ready?: fn -> false end}}
      assert {:error, %Error{kind: :host_not_ready}} = patch(unready, spec, spec.body)

      if spec.extension do
        unsupported = %{client | server: %Server{api_extensions: []}}

        assert {:error, %Error{kind: :unsupported_extension}} =
                 patch(unsupported, spec, spec.body)
      end

      assert HTTPFixture.requests(fixture) == []
    end
  end

  defp compare(root, identity, spec, body, code) do
    fixture = backend(root, identity, fn _ -> response(code, spec) end)
    client = client(fixture, identity)

    input =
      Map.merge(native_connection(fixture, identity), %{
        action: "RawQuery",
        args: [
          "PATCH",
          spec.path <> "?project=fixture+scope&target=member%2Fa",
          body,
          "\"before\""
        ]
      })

    file = Path.join(root, "oracle.json")
    File.write!(file, Jason.encode!(input))
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    expected = Jason.decode!(out)
    actual = patch(client, spec, body)
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
      assert reply.etag == Enum.at(expected["outputs"], 1)
      assert hd(expected["outputs"])["metadata"] == Model.encode(reply.metadata)
      assert reply.connection == client.connection and reply.identity == :verified

      if spec.accepted do
        assert reply.http_status == 202 and reply.type == "async"
        assert reply.operation == "/1.0/operations/received"
        assert {:ok, operation} = Operation.from_response(client, reply)
        assert operation.url == reply.operation and operation.client == client
        assert reply.metadata.data["status_code"] == 100
      else
        assert reply.http_status == 200 and reply.type == "sync" and reply.metadata == %{}
        assert reply.operation == ""

        assert {:error, %Error{kind: :invalid_operation_binding}} =
                 Operation.from_response(client, reply)
      end
    else
      assert {:error,
              %Error{kind: :native, http_status: ^code, error_code: ^code, message: message}} =
               actual

      assert expected["error"] == message and expected["error_status"] == code
    end
  end

  defp patch(client, spec, body),
    do: Incus.call(client, spec.method, spec.args, body: body, etag: "\"before\"")

  defp response(200, %{accepted: true}),
    do: %{
      status: 202,
      headers: %{"ETag" => "\"after\""},
      body: %{
        type: "async",
        status_code: 100,
        operation: "/1.0/operations/received",
        metadata: %{id: "received", status: "Running", status_code: 100}
      }
    }

  defp response(code, %{method: "PatchInstance"}), do: response(code)
  defp response(200, _), do: response(200)

  defp response(code, _),
    do: %{status: code, body: %{type: "error", error_code: code, error: "native rejection"}}

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
                   metadata: %{
                     api_version: "1.0",
                     api_extensions: ["projects", "snapshot_expiry"],
                     environment: %{}
                   }
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
      server: %Server{api_extensions: ["projects", "snapshot_expiry"]}
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
