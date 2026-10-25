defmodule Opsmaru.Incus.SyncMutationContractTest do
  @moduledoc "B09/B10 write contracts compared with the named pinned Go methods."
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Operation, RequestContext, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, ModelSamples, TLSIdentity, WireComparison}
  @driver Path.expand("../.integration/sync-mutation-driver", __DIR__)

  # B09 PR 2: every synchronous network write (create, rename, update, delete).
  @b09 ~w(CreateNetwork RenameNetwork UpdateNetwork DeleteNetwork CreateNetworkACL RenameNetworkACL UpdateNetworkACL DeleteNetworkACL CreateNetworkAddressSet RenameNetworkAddressSet UpdateNetworkAddressSet DeleteNetworkAddressSet CreateNetworkIntegration RenameNetworkIntegration UpdateNetworkIntegration DeleteNetworkIntegration CreateNetworkZone UpdateNetworkZone DeleteNetworkZone CreateNetworkZoneRecord UpdateNetworkZoneRecord DeleteNetworkZoneRecord CreateNetworkForward UpdateNetworkForward DeleteNetworkForward CreateNetworkLoadBalancer UpdateNetworkLoadBalancer DeleteNetworkLoadBalancer CreateNetworkPeer UpdateNetworkPeer DeleteNetworkPeer)
  # B10 PR 2: every administrative write, synchronous or accepted as an operation.
  @b10 ~w(UpdateServer CreateCertificate CreateCertificateToken UpdateCertificate DeleteCertificate UpdateCluster UpdateClusterCertificate CreateClusterGroup RenameClusterGroup UpdateClusterGroup DeleteClusterGroup CreateClusterMember RenameClusterMember UpdateClusterMember DeleteClusterMember DeletePendingClusterMember UpdateClusterMemberState CreateProfile RenameProfile UpdateProfile DeleteProfile CreateProject RenameProject UpdateProject DeleteProject DeleteProjectForce UpdateWarning DeleteWarning)
  # B08 PR 2: every stream-free storage write (pools, buckets and keys, volumes,
  # bitmaps, volume snapshots and rebuild).
  @b08 ~w(CreateStoragePool UpdateStoragePool DeleteStoragePool UpdateStoragePoolBucket DeleteStoragePoolBucket CreateStoragePoolBucketKey UpdateStoragePoolBucketKey DeleteStoragePoolBucketKey UpdateStoragePoolVolume DeleteStoragePoolVolume CreateStorageVolumeBitmap DeleteStorageVolumeBitmap CreateStoragePoolVolumeSnapshot RenameStoragePoolVolumeSnapshot UpdateStoragePoolVolumeSnapshot DeleteStoragePoolVolumeSnapshot RebuildStoragePoolVolume)
  # B11: every stream-free instance and image write.
  @b11 ~w(CreateImageAlias RenameImageAlias UpdateImageAlias DeleteImageAlias UpdateImage RefreshImage CreateImageSecret UpdateInstanceMetadata DeleteInstanceConsoleLog DeleteInstanceLogfile CreateInstanceBitmap RebuildInstance UpdateInstanceSnapshot UpdateInstances)
  @all_methods Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
  @methods Enum.filter(@all_methods, &(&1["name"] in (@b09 ++ @b10 ++ @b08 ++ @b11)))
  @extensions ~w(network network_acl network_address_set network_integrations network_dns network_dns_records network_forward network_load_balancer network_peer certificate_token certificate_update clustering clustering_edit_roles clustering_evacuation clustering_failure_domains clustering_groups clustering_join clustering_join_token clustering_update_cert projects projects_force_delete warnings storage storage_buckets storage_volume_nbd storage_api_volume_snapshots storage_volumes_rebuild console container_log_delete image_force_refresh instances_rebuild container_edit_metadata snapshot_expiry)
  @uuid "01234567-89ab-cdef-0123-456789abcdef"
  @url "/1.0/operations/" <> @uuid
  @etag "\"before\""

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert length(@methods) == 90
    assert Enum.all?(@methods, &(&1["result"] in ["sync", "model", "operation"]))
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-sync-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # The volume type is a pass-through path argument, compared for every daemon type.
  @volume_types ~w(custom container virtual-machine image)

  for method <- @methods, method["result"] in ["sync", "model"], transport <- [:unix, :https] do
    test "#{method["name"]} #{transport} synchronous write matches native request, result and rejection",
         %{root: root} do
      method = unquote(Macro.escape(method))
      identity = identity(root, unquote(transport))

      for outcome <- [:sync, 400, 403, 404, 409, 412, :eof, :malformed],
          do: compare(root, identity, method, outcome)

      # An unset force flag sends no force query, as in the pinned client.
      if "force" in method["params"], do: compare(root, identity, method, :sync, false)
      # A returned model that the pinned DTO rejects leaves the write uncertain.
      if method["result"] == "model", do: compare(root, identity, method, :corrupt)

      for type <- volume_types(method),
          do: compare(root, identity, Map.put(method, "volume_type", type), :sync)

      preflight(root, identity, method)
    end
  end

  for method <- @methods, method["result"] == "operation", transport <- [:unix, :https] do
    test "#{method["name"]} #{transport} asynchronous write matches native request, operation and wait",
         %{root: root} do
      method = unquote(Macro.escape(method))
      identity = identity(root, unquote(transport))

      # Accepted, then native /wait running, completed, failed and cancelled snapshots.
      waits = for code <- [103, 200, 400, 401], do: {:wait, code}

      for outcome <- waits ++ [:bad_operation, 400, 403, 404, 409, 412, :eof, :malformed],
          do: compare(root, identity, method, outcome)

      for type <- volume_types(method),
          do: compare(root, identity, Map.put(method, "volume_type", type), {:wait, 200})

      preflight(root, identity, method)
    end
  end

  for transport <- [:unix, :https] do
    test "#{transport} guarded administrative fields reject before dispatch", %{root: root} do
      identity = identity(root, unquote(transport))

      for method <- @methods, method["name"] in @b10, guard <- method["guards"] do
        others = for other <- method["guards"], other != guard, do: other["field"]
        guarded(root, identity, method, guard, Map.drop(body(method), others))
      end
    end

    test "#{transport} guarded storage fields reject before dispatch", %{root: root} do
      identity = identity(root, unquote(transport))
      methods = for method <- @methods, method["name"] in @b08, method["guards"] != [], do: method
      assert Enum.map(methods, & &1["name"]) == ["UpdateStoragePoolVolume"]

      for method <- methods,
          guard <- method["guards"],
          do: guarded(root, identity, method, guard, body(method))
    end

    test "#{transport} untrusted clients bootstrap trust with a trust token", %{root: root} do
      identity = identity(root, unquote(transport))
      method = Enum.find(@methods, &(&1["name"] == "CreateCertificate"))

      body = %{
        "name" => "fixture-client",
        "type" => "client",
        "trust_token" => "fixture-trust-token"
      }

      for outcome <- [:sync, 403] do
        fixture = backend(root, identity, fn _ -> reply(outcome) end, @extensions, "untrusted")
        expected = oracle(root, fixture, identity, method, %{}, body)
        context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)

        # Discovery reports the untrusted client; the trust-token request still dispatches.
        assert {:ok, client} = Incus.connect(client(fixture, identity, []).connection, context)
        assert client.server.auth == "untrusted"
        actual = call(client, method, normalized(expected, method, body))
        assert [%{method: "GET"}, native, %{method: "GET"}, local] = HTTPFixture.requests(fixture)
        assert WireComparison.request(native) == WireComparison.request(local)
        assert Jason.decode!(local.body)["trust_token"] == "fixture-trust-token"

        case outcome do
          :sync ->
            refute expected["error"]
            assert {:ok, %{type: "sync", http_status: 200}} = actual

          403 ->
            assert expected["error_status"] == 403

            assert {:error, %Error{kind: :native, http_status: 403, message: message}} = actual
            assert expected["error"] == message
        end
      end
    end
  end

  for transport <- [:unix, :https] do
    test "#{transport} non-local network peers require network_integrations before dispatch", %{
      root: root
    } do
      identity = identity(root, unquote(transport))
      method = Enum.find(@methods, &(&1["name"] == "CreateNetworkPeer"))
      extensions = @extensions -- ["network_integrations"]

      fixture =
        backend(root, identity, fn _ -> flunk("guarded write was dispatched") end, extensions)

      body = %{body(method) | "type" => "remote"}
      expected = oracle(root, fixture, identity, method, args(method), body)
      assert expected["error"] =~ "network_integrations"

      assert {:error, %Error{kind: :unsupported_extension, extension: "network_integrations"}} =
               Incus.call(client(fixture, identity, extensions), method["name"], args(method),
                 body: body
               )

      # Only the pinned client's server discovery reached the fixture.
      assert [%{method: "GET", target: "/1.0"}] = HTTPFixture.requests(fixture)

      # A local peer needs no integration extension, as in the pinned client.
      local = %{body | "type" => "local"}
      fixture = backend(root, identity, fn _ -> reply(:sync) end, extensions)
      assert {:ok, _} = call(client(fixture, identity, extensions), method, local)
    end
  end

  defp compare(root, identity, method, outcome, force \\ true) do
    fixture = backend(root, identity, &respond(outcome, method, &1))

    body = body(method)
    args = args(method, force)
    expected = oracle(root, fixture, identity, method, args, body)
    client = client(fixture, identity, @extensions)

    actual =
      Incus.call(client, method["name"], args, opts(method, normalized(expected, method, body)))

    assert [%{method: "GET"}, native, local] = HTTPFixture.requests(fixture)
    assert local.method == method["verb"]
    assert WireComparison.request(native) == WireComparison.request(local)
    query = URI.decode_query(URI.parse(local.target).query || "")

    assert Map.take(query, ~w(project target)) == %{
             "project" => "fixture scope",
             "target" => "member/a"
           }

    if method["verb"] == "PUT", do: assert(local.headers["if-match"] == @etag)

    case outcome do
      {:wait, code} ->
        refute expected["error"]
        accepted(root, fixture, identity, client, actual, expected, code)

      _ ->
        check(outcome, actual, expected, client, method)
    end
  end

  # An accepted write answers its own /wait with the requested snapshot.
  defp respond({:wait, code}, _method, request) do
    if String.ends_with?(URI.parse(request.target).path, "/wait"),
      do: envelope(200, "sync", snapshot(code)),
      else: envelope(202, "async", snapshot(103))
  end

  # A model-returning write answers with a schema-generated (or corrupted) model.
  defp respond(outcome, %{"result" => "model", "model" => model}, _request)
       when outcome in [:sync, :corrupt],
       do: envelope(200, "sync", if(outcome == :sync, do: model(model), else: corrupt(model)))

  defp respond(outcome, _method, _request), do: reply(outcome)

  defp check(outcome, actual, expected, client, method) do
    case outcome do
      :sync ->
        refute expected["error"]
        assert {:ok, reply} = actual
        assert {reply.type, reply.http_status} == {"sync", 200}
        assert reply.connection == client.connection and reply.identity == :verified

        # A returned model is decoded and agrees with the pinned DTO field by field.
        if method["result"] == "model" do
          assert reply.metadata.data == model(method["model"])
          assert sent?(hd(expected["outputs"]), model(method["model"]))
        end

      :corrupt ->
        assert expected["error"]
        assert {:error, %Error{kind: :uncertain}} = actual

      code when is_integer(code) ->
        assert {:error,
                %Error{kind: :native, http_status: ^code, error_code: ^code, message: message}} =
                 actual

        assert expected["error_status"] == code and expected["error"] == message

      # A dispatched write whose reply is lost or malformed may have taken effect.
      lost when lost in [:eof, :malformed] ->
        assert expected["error"]
        assert {:error, %Error{kind: :uncertain, operation: nil}} = actual

      # Acceptance with an unusable operation keeps its identity and is never replayed.
      :bad_operation ->
        assert expected["error"]
        assert {:error, %Error{kind: :uncertain, operation: @url}} = actual
    end
  end

  # The accepted operation binds to its connection; native /wait reports its outcome.
  defp accepted(root, fixture, identity, client, actual, expected, code) do
    assert {:ok, reply} = actual
    assert {reply.type, reply.http_status, reply.operation} == {"async", 202, @url}
    assert reply.connection == client.connection and reply.identity == :verified
    assert {:ok, operation} = Operation.from_response(client, reply)
    assert operation.client == client and operation.url == @url
    refute Operation.completed?(operation)
    assert reply.metadata.data == snapshot(103)
    # Operation metadata (an image secret, for one) never appears in Inspect output.
    refute inspect(reply) =~ "retained" or inspect(operation) =~ "retained"
    assert Map.take(hd(expected["outputs"]), Map.keys(snapshot(103))) == snapshot(103)

    timeout = if code == 103, do: 0, else: 1
    wait = Enum.find(@all_methods, &(&1["name"] == "GetOperationWait"))

    expected =
      oracle(root, fixture, identity, wait, %{"uuid" => @uuid, "timeout" => timeout}, nil)

    assert {:ok, waited} =
             Incus.call(client, "GetOperationWait", %{"uuid" => @uuid, "timeout" => timeout})

    assert [_, _, _, %{method: "GET"}, native_wait, local_wait] = HTTPFixture.requests(fixture)
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

    assert length(HTTPFixture.requests(fixture)) == 6
  end

  # Without the guard's extension, or with a required value unmet, both clients
  # reject before sending the write.
  defp guarded(root, identity, method, %{"extension" => extension}, body) do
    extensions = @extensions -- [extension]

    fixture =
      backend(root, identity, fn _ -> flunk("guarded write was dispatched") end, extensions)

    expected = oracle(root, fixture, identity, method, args(method), body)
    assert expected["error"] =~ extension

    assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
             call(client(fixture, identity, extensions), method, body)

    # Only the pinned client's server discovery reached the fixture.
    assert [%{method: "GET", target: "/1.0"}] = HTTPFixture.requests(fixture)
  end

  defp guarded(root, identity, method, %{"field" => field, "equals" => value}, body) do
    body = Map.put(body, field, not value)
    fixture = backend(root, identity, fn _ -> flunk("guarded write was dispatched") end)
    expected = oracle(root, fixture, identity, method, args(method), body)
    assert expected["error"]

    assert {:error, %Error{kind: :invalid_body}} =
             call(client(fixture, identity, @extensions), method, body)

    assert [%{method: "GET", target: "/1.0"}] = HTTPFixture.requests(fixture)
  end

  # Invalid input, unready hosts and missing extensions reject before any I/O.
  defp preflight(root, identity, method) do
    fixture = backend(root, identity, fn _ -> flunk("preflight write was dispatched") end)
    client = client(fixture, identity, @extensions)

    if method["body"] do
      # An empty model (rebuild) has no field to break, so its body is not a map.
      invalid =
        case Enum.sort(body(method)) do
          [] -> "invalid"
          [{field, _} | _] -> Map.put(body(method), field, %{"invalid" => self()})
        end

      assert {:error, %Error{kind: :invalid_body}} =
               Incus.call(client, method["name"], args(method), opts(method, invalid))
    end

    unready = %{
      client
      | context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> false end)
    }

    assert {:error, %Error{kind: :host_not_ready}} = call(unready, method, body(method))

    for extension <- List.wrap(method["extension"]) do
      missing = %{client | server: %Server{api_extensions: List.delete(@extensions, extension)}}

      assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
               call(missing, method, body(method))
    end

    assert HTTPFixture.requests(fixture) == []
  end

  defp call(client, method, body),
    do: Incus.call(client, method["name"], args(method), opts(method, body))

  defp opts(method, body) do
    opts = if method["body"], do: [body: body], else: []
    if method["verb"] == "PUT", do: Keyword.put(opts, :etag, @etag), else: opts
  end

  # The pinned client's decoded body, so both sides send the same typed value. Every
  # generated field must survive Go's decoding at every depth, so a field the DTO
  # drops cannot silently shrink the every-field coverage.
  defp normalized(_expected, %{"body" => nil}, _body), do: nil

  defp normalized(expected, method, body) do
    decoded = Enum.at(expected["normalized_args"], length(method["params"]))
    assert decoded, "pinned client returned no normalized body"
    assert sent?(decoded, body), "pinned DTO dropped or changed a generated field"
    decoded
  end

  # The decoded value keeps every sent field and value; Go may add zero-valued fields.
  defp sent?(decoded, sent) when is_map(sent),
    do: is_map(decoded) and Enum.all?(sent, fn {key, value} -> sent?(decoded[key], value) end)

  defp sent?(decoded, sent) when is_list(sent),
    do:
      is_list(decoded) and length(decoded) == length(sent) and
        Enum.all?(Enum.zip(decoded, sent), fn {d, v} -> sent?(d, v) end)

  defp sent?(decoded, sent), do: decoded == sent

  defp body(%{"body" => nil}), do: nil

  # A local peer avoids the integration guard; that guard has its own test.
  defp body(%{"name" => "CreateNetworkPeer", "body" => model}),
    do: %{ModelSamples.generate(model) | "type" => "local"}

  # A plain certificate addition is not a token request; that guard has its own test.
  defp body(%{"name" => "CreateCertificate", "body" => model}),
    do: %{ModelSamples.generate(model) | "token" => false}

  defp body(%{"body" => model}), do: ModelSamples.generate(model)

  # The pinned client leaves legal parameters unescaped, so they carry no reserved characters.
  defp args(method, force \\ true),
    do:
      Map.new(method["params"], fn
        "force" -> {"force", force}
        param when param in ~w(volType volumeType) -> {param, volume_type(method, param)}
        param -> {param, legal(method, param) <> param}
      end)

  defp volume_type(method, param), do: Map.get(method, "volume_type", "fixture /" <> param)

  defp volume_types(method) do
    if Enum.any?(method["params"], &(&1 in ~w(volType volumeType))), do: @volume_types, else: []
  end

  defp model(model), do: ModelSamples.generate(model)

  # The first string field becomes a number, which the pinned DTO rejects.
  defp corrupt(model) do
    sample = model(model)
    [{field, _} | _] = Enum.filter(Enum.sort(sample), fn {_, value} -> is_binary(value) end)
    %{sample | field => 7}
  end

  defp legal(method, param),
    do: if(param in Map.get(method, "legal_params", []), do: "fixture-", else: "fixture /")

  defp oracle(root, fixture, identity, method, args, body) do
    # Trailing pinned arguments the catalogue records, such as unused console log options.
    values =
      Enum.map(method["params"], &args[&1]) ++
        Map.get(method, "oracle_trailing", []) ++
        if(body, do: [body], else: []) ++
        if(method["verb"] == "PUT", do: [@etag], else: [])

    input =
      Map.merge(native_connection(fixture, identity), %{
        action: method["name"],
        args: values,
        project: "fixture scope",
        target: "member/a"
      })

    file = Path.join(root, "oracle.json")
    File.write!(file, Jason.encode!(input))
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end

  defp reply(:sync),
    do: %{
      status: 200,
      headers: %{"ETag" => "\"after\""},
      body: %{type: "sync", status_code: 200, metadata: %{}}
    }

  defp reply(:bad_operation), do: envelope(202, "async", %{"status_code" => "bad"})

  defp reply(:eof), do: %{upgrade: fn _, _ -> :ok end}
  defp reply(:malformed), do: %{status: 200, body: "malformed"}

  defp reply(code),
    do: %{status: code, body: %{type: "error", error_code: code, error: "native write rejection"}}

  defp envelope(status, type, data),
    do: %{
      status: status,
      headers: %{"ETag" => "\"lifecycle\""},
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

  defp identity(_root, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "sync-#{System.unique_integer([:positive])}", "localhost")

  defp backend(root, identity, handler, extensions \\ @extensions, auth \\ "trusted") do
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
             # Discovery only: PUT /1.0 is the UpdateServer write under test.
             if request.method == "GET" and URI.parse(request.target).path == "/1.0",
               do: %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{
                     api_version: "1.0",
                     api_extensions: extensions,
                     auth: auth,
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

  defp client(fixture, identity, extensions) do
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
      server: %Server{api_extensions: extensions}
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
