defmodule Opsmaru.Incus.PatchContractTest do
  @moduledoc "B05 conditional PATCH contracts compared with unchanged pinned Go RawQuery."
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Model, Operation, RequestContext, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, ModelSamples, TLSIdentity, WireComparison}
  @driver Path.expand("../.integration/patch-contract-driver", __DIR__)

  # B05: the four earlier descriptors, administrative, image alias and instance
  # metadata PATCH (PR 1), then network and custom-volume storage PATCH (PR 2). The
  # pinned client has no PATCH method.
  @b05 ~w(PatchProject PatchProfile PatchImage PatchInstanceSnapshot PatchServer PatchCertificate PatchClusterGroup PatchClusterMember PatchImageAlias PatchInstanceMetadata PatchWarning PatchNetworkACL PatchNetworkAddressSet PatchNetworkIntegration PatchNetworkZone PatchNetworkZoneRecord PatchNetwork PatchNetworkForward PatchNetworkLoadBalancer PatchNetworkPeer PatchStoragePool PatchStoragePoolBucket PatchStoragePoolVolume PatchStoragePoolVolumeSnapshot)
  @all_methods Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
  @methods Enum.filter(@all_methods, &(&1["name"] in @b05))
  @extensions ~w(projects snapshot_expiry certificate_update clustering_groups clustering_edit_roles clustering_failure_domains container_edit_metadata warnings network network_acl network_address_set network_integrations network_dns network_dns_records network_forward network_load_balancer network_peer storage storage_buckets storage_api_volume_snapshots)
  @etag "\"before\""
  @uuid "01234567-89ab-cdef-0123-456789abcdef"
  @url "/1.0/operations/" <> @uuid

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out

    # Every REST PATCH descriptor is B04 instance PATCH or a B05 method here.
    rest =
      for method <- @all_methods,
          method["reference_kind"] == "rest" and method["verb"] == "PATCH",
          do: method["name"]

    assert Enum.sort(rest) == Enum.sort(["PatchInstance" | @b05])
    assert length(@methods) == 24 and Enum.all?(@methods, &(&1["conditional"] == true))
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-pc-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for method <- @methods, transport <- [:unix, :https] do
    test "#{method["name"]} #{transport} conditional PATCH matches native request, field presence and result",
         %{root: root} do
      method = unquote(Macro.escape(method))
      identity = identity(root, unquote(transport))

      for body <- bodies(method), do: compare(root, identity, method, body, 200)
      for code <- [400, 403, 404, 412], do: compare(root, identity, method, %{}, code)

      # An accepted PATCH is observed through native /wait like any other operation.
      if method["result"] == "operation",
        do: for(code <- [103, 200, 400, 401], do: wait(root, identity, method, code))
    end

    test "#{method["name"]} #{transport} dispatched PATCH failures stay uncertain without replay",
         %{root: root} do
      method = unquote(Macro.escape(method))
      identity = identity(root, unquote(transport))
      accepted? = method["result"] == "operation"

      for reply <- [
            %{upgrade: fn _, _ -> :ok end},
            %{status: 200, body: "malformed"},
            %{status: 200, body: %{type: "sync", status_code: 200, metadata: nil}},
            # The other result kind than the daemon returns for this method.
            if(accepted?, do: success(), else: accepted())
          ] do
        fixture = backend(root, identity, fn _ -> reply end)

        assert {:error, %Error{kind: :uncertain} = error} =
                 patch(client(fixture, identity), method, body(method))

        if is_map(reply[:body]) and reply.body[:type] == "async",
          do: assert(error.operation == @url),
          else: assert(error.operation in [nil, ""])

        assert [%{method: "PATCH"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{method["name"]} #{transport} dispatched PATCH deadline and cancellation close the peer",
         %{root: root} do
      method = unquote(Macro.escape(method))
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

        task =
          Task.async(fn -> patch(Incus.with_context(original, scope), method, body(method)) end)

        assert_receive {^tag, :entered}, 10_000
        if mode == :cancel, do: RequestContext.cancel(scope)
        assert {:error, %Error{kind: :uncertain, operation: nil}} = Task.await(task, 10_000)
        assert_receive {^tag, :closed, {:error, :closed}}, 10_000
        assert original.connection.request_context == nil
        assert [%{method: "PATCH"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{method["name"]} #{transport} conditional PATCH preflight rejects invalid input without I/O",
         %{root: root} do
      method = unquote(Macro.escape(method))
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> flunk("preflight PATCH was dispatched") end)
      client = client(fixture, identity)
      args = args(method)
      body = body(method)
      [{field, _} | _] = Enum.sort(body)
      invalid = Map.put(body, field, %{"invalid" => self()})

      # Unconditional PATCH (no ETag) is an approved exclusion and never dispatches.
      for {args, opts} <-
            [
              {args, [body: body]},
              {args, [body: body, etag: ""]},
              {args, [body: body, etag: String.duplicate("e", 1025)]},
              {args, [body: body, etag: "first", etag: "second"]},
              {args, [body: invalid, etag: @etag]},
              {args, [body: body, etag: "before\r\nInjected: true"]}
            ] ++ for({key, _} <- args, do: {Map.put(args, key, ""), [body: body, etag: @etag]}) do
        assert {:error, %Error{kind: kind}} = Incus.call(client, method["name"], args, opts)
        refute kind == :uncertain
      end

      small = %{client | connection: %{client.connection | max_request_bytes: 16}}
      assert {:error, %Error{kind: :invalid_body}} = patch(small, method, body)
      unready = %{client | context: %{client.context | ready?: fn -> false end}}
      assert {:error, %Error{kind: :host_not_ready}} = patch(unready, method, body)

      for extension <- List.wrap(method["extension"]) do
        missing = %{client | server: %Server{api_extensions: @extensions -- [extension]}}

        assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
                 patch(missing, method, body)
      end

      # Guarded fields need their extension, as on the pinned PUT counterpart.
      for %{"extension" => extension} <- method["guards"] do
        missing = %{client | server: %Server{api_extensions: @extensions -- [extension]}}

        assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
                 patch(missing, method, body)
      end

      assert HTTPFixture.requests(fixture) == []
    end
  end

  # Empty, one field, every field (schema-generated at every depth), every field
  # cleared, explicit nulls and an unknown field: PATCH sends exactly what the
  # caller supplied.
  defp bodies(method) do
    body = body(method)
    [{field, value} | _] = Enum.sort(body)

    [
      %{},
      %{field => value},
      body,
      Map.new(body, fn {key, value} -> {key, cleared(value)} end),
      Map.new(body, fn {key, _} -> {key, nil} end),
      Map.put(body, "future_field", false)
    ]
  end

  # The value a caller sends to clear a setting: false, empty or zero. A cleared
  # timestamp is Go's zero time, as clients send to remove an expiry.
  defp cleared(true), do: false
  defp cleared("2026-10-22T12:00:00Z"), do: "0001-01-01T00:00:00Z"
  defp cleared(value) when is_binary(value), do: ""
  defp cleared(value) when is_list(value), do: []
  defp cleared(value) when is_map(value), do: %{}
  defp cleared(value) when is_integer(value), do: 0
  defp cleared(value) when is_float(value), do: 0.0

  defp body(%{"body" => model}), do: ModelSamples.generate(model)

  defp args(method), do: Map.new(method["params"], &{&1, "fixture /" <> &1})

  # The expected native path, escaped independently of the client.
  defp path(method),
    do:
      Enum.reduce(method["params"], method["path"], fn param, path ->
        String.replace(path, "{" <> param <> "}", "fixture%20%2F" <> param)
      end)

  defp compare(root, identity, method, body, code) do
    fixture = backend(root, identity, fn _ -> response(code, method) end)
    client = client(fixture, identity)

    expected =
      raw_query(root, fixture, identity, ["PATCH", path(method) <> routing(), body, @etag])

    actual = patch(client, method, body)
    assert [%{method: "GET"}, native, local] = HTTPFixture.requests(fixture)
    assert native.method == "PATCH" and URI.parse(local.target).path == path(method)
    assert Jason.decode!(local.body) == body
    assert local.headers["if-match"] == @etag

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
      result(client, method, reply)
    else
      assert {:error,
              %Error{kind: :native, http_status: ^code, error_code: ^code, message: message}} =
               actual

      assert expected["error"] == message and expected["error_status"] == code
    end
  end

  defp result(client, %{"result" => "operation"}, reply) do
    assert {reply.http_status, reply.type, reply.operation} == {202, "async", @url}
    assert {:ok, operation} = Operation.from_response(client, reply)
    assert operation.url == @url and operation.client == client
    refute Operation.completed?(operation)
  end

  defp result(client, _method, reply) do
    assert {reply.http_status, reply.type, reply.metadata, reply.operation} ==
             {200, "sync", %{}, ""}

    assert {:error, %Error{kind: :invalid_operation_binding}} =
             Operation.from_response(client, reply)
  end

  # Native /wait snapshots for the accepted PATCH, compared with the named Go
  # GetOperationWait, then local deadline and cancellation of the wait.
  defp wait(root, identity, method, code) do
    fixture =
      backend(root, identity, fn request ->
        if String.ends_with?(URI.parse(request.target).path, "/wait"),
          do: envelope(200, "sync", snapshot(code)),
          else: accepted()
      end)

    client = client(fixture, identity)
    assert {:ok, reply} = patch(client, method, body(method))
    assert {:ok, operation} = Operation.from_response(client, reply)
    assert reply.metadata.data == snapshot(103)
    timeout = if code == 103, do: 0, else: 1

    input =
      Map.merge(native_connection(fixture, identity), %{
        action: "GetOperationWait",
        args: [@uuid, timeout],
        project: "fixture scope",
        target: "member/a"
      })

    expected = oracle(root, input)

    assert {:ok, waited} =
             Incus.call(client, "GetOperationWait", %{"uuid" => @uuid, "timeout" => timeout})

    # Only the pinned client discovers the server before its wait.
    assert [%{method: "PATCH"}, %{method: "GET"}, native_wait, local_wait] =
             HTTPFixture.requests(fixture)

    assert WireComparison.request(native_wait) == WireComparison.request(local_wait)
    assert URI.parse(local_wait.target).path == @url <> "/wait"
    assert waited.metadata.data == snapshot(code)
    assert Map.take(hd(expected["outputs"]), Map.keys(snapshot(code))) == snapshot(code)
    current = %{operation | response: waited}
    assert Operation.completed?(current) == (code != 103)
    assert Operation.successful?(current) == (code == 200)

    # Local deadline and cancellation end only the local wait; the handle is unchanged.
    for kind <- [:deadline, :canceled] do
      context = RequestContext.new!(timeout: 30_000)

      context =
        if kind == :deadline,
          do: %{context | deadline: System.monotonic_time(:millisecond) - 1},
          else: context

      if kind == :canceled, do: RequestContext.cancel(context)

      assert {:error, %Error{kind: ^kind}} =
               Incus.call(Incus.with_context(client, context), "GetOperationWait", %{
                 "uuid" => @uuid,
                 "timeout" => 1
               })

      assert operation.url == @url and operation.client.connection.request_context == nil
    end

    assert length(HTTPFixture.requests(fixture)) == 4
  end

  defp patch(client, method, body),
    do: Incus.call(client, method["name"], args(method), body: body, etag: @etag)

  defp routing, do: "?project=fixture+scope&target=member%2Fa"

  defp raw_query(root, fixture, identity, args),
    do:
      oracle(
        root,
        Map.merge(native_connection(fixture, identity), %{action: "RawQuery", args: args})
      )

  defp oracle(root, input) do
    file = Path.join(root, "oracle.json")
    File.write!(file, Jason.encode!(input))
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end

  defp response(200, %{"result" => "operation"}), do: accepted()
  defp response(200, _), do: success()

  defp response(code, _),
    do: %{status: code, body: %{type: "error", error_code: code, error: "native rejection"}}

  defp success,
    do: %{
      status: 200,
      headers: %{"ETag" => "\"after\""},
      body: %{type: "sync", status_code: 200, metadata: %{}}
    }

  defp accepted, do: envelope(202, "async", snapshot(103))

  defp envelope(status, type, data),
    do: %{
      status: status,
      headers: %{"ETag" => "\"after\""},
      body: %{
        type: type,
        status_code: if(type == "async", do: 100, else: 200),
        operation: if(type == "async", do: @url, else: ""),
        metadata: data
      }
    }

  defp snapshot(code),
    do: %{
      "id" => @uuid,
      "status_code" => code,
      "status" =>
        %{103 => "Running", 200 => "Success", 400 => "Failure", 401 => "Cancelled"}[code],
      "err" => %{400 => "fixture failure", 401 => "operation canceled"}[code] || "",
      "may_cancel" => true,
      "metadata" => %{"fixture" => "retained"}
    }

  defp identity(_, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "patch-#{System.unique_integer([:positive])}", "localhost")

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
             # Discovery only: PATCH /1.0 is the PatchServer write under test.
             if request.method == "GET" and URI.parse(request.target).path == "/1.0",
               do: %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{api_version: "1.0", api_extensions: @extensions, environment: %{}}
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
      server: %Server{api_extensions: @extensions}
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
