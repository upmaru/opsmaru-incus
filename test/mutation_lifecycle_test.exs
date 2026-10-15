defmodule Opsmaru.Incus.MutationLifecycleTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Operation, RequestContext, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}
  @driver Path.expand("../.integration/mutation-driver", __DIR__)
  @uuid "01234567-89ab-cdef-0123-456789abcdef"
  @url "/1.0/operations/" <> @uuid
  @flows [
    {"CreateInstance", %{},
     %{
       "name" => "guest",
       "source" => %{"type" => "image", "fingerprint" => "abc"},
       "config" => %{"user.note" => "fixture"}
     }},
    {"UpdateInstance", %{"name" => "guest /one"},
     %{
       "config" => %{"user.note" => "fixture"},
       "devices" => %{"data" => %{"type" => "disk", "path" => "/data", "pool" => "fixture"}}
     }},
    {"UpdateInstance", %{"name" => "guest /one"}, %{"restore" => "snapshot-a"}},
    {"UpdateInstanceState", %{"name" => "guest /one"},
     %{"action" => "stop", "timeout" => 10, "force" => false}},
    {"DeleteInstance", %{"name" => "guest /one"}, nil},
    {"CreateInstanceSnapshot", %{"instance_name" => "guest /one"},
     %{"name" => "snapshot-a", "stateful" => false}},
    {"DeleteInstanceSnapshot", %{"instance_name" => "guest /one", "name" => "snapshot /one"},
     nil},
    {"DeleteImage", %{"fingerprint" => "image /one"}, nil},
    {"DeleteOperation", %{"uuid" => @uuid}, nil}
  ]
  @methods Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
           |> Map.new(&{&1["name"], &1})

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out

    assigned =
      Jason.decode!(File.read!("priv/incus/endpoint-inventory.json"))["entries"]
      |> Enum.filter(&(&1["backlog"] == "B01"))
      |> Enum.flat_map(& &1["methods"])

    assert length(@flows) == 9
    assert Enum.sort(Enum.uniq(Enum.map(@flows, &elem(&1, 0)))) == Enum.sort(assigned)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-mut-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} B01 native mutation lifecycle contracts", %{root: root} do
      identity =
        if unquote(transport) == :https, do: TLSIdentity.generate(root, "mutation", "localhost")

      for {name, args, body} <- @flows do
        outcomes =
          if name == "DeleteOperation", do: [:sync], else: [103, 200, 400, :bad_operation]

        for outcome <- outcomes ++ [403, 404, 409, 412, :eof, :malformed],
            do: compare(root, identity, @methods[name], args, body, outcome)
      end
    end

    test "#{transport} B01 cancellation permission races rejection and response loss", %{
      root: root
    } do
      identity =
        if unquote(transport) == :https, do: TLSIdentity.generate(root, "cancel", "localhost")

      for mode <- [:allowed, :unsupported, :completed, :forbidden, :lost] do
        fixture =
          backend(root, identity, fn request ->
            if request.method == "GET",
              do:
                envelope(
                  200,
                  "sync",
                  snapshot(if(mode == :completed, do: 200, else: 103), mode != :unsupported)
                ),
              else:
                mutation_reply(
                  if(mode == :forbidden, do: 403, else: if(mode == :lost, do: :eof, else: :sync))
                )
          end)

        client = client(fixture, identity)
        operation = %Operation{client: client, url: @url}
        result = Operation.cancel(operation)

        case mode do
          :unsupported ->
            assert {:error, %Error{kind: :cancellation_unsupported, operation: @url}} = result

          :forbidden ->
            assert {:error, %Error{kind: :native, http_status: 403, operation: @url}} = result

          :lost ->
            assert {:error, %Error{kind: :uncertain, operation: @url}} = result

          :completed ->
            assert {:ok, current} = result
            assert Operation.successful?(current)

          :allowed ->
            assert {:ok, requested} = result
            assert requested.url == @url and requested.client == client
            assert requested.response.type == "sync"
            refute Operation.completed?(requested)
        end

        requests = HTTPFixture.requests(fixture)

        assert Enum.map(requests, & &1.method) ==
                 if(mode in [:unsupported, :completed], do: ["GET"], else: ["GET", "DELETE"])

        assert Enum.all?(requests, &(URI.parse(&1.target).path == @url))
      end
    end
  end

  defp compare(root, identity, method, args, body, outcome) do
    fixture =
      backend(root, identity, fn request ->
        if String.ends_with?(URI.parse(request.target).path, "/wait"),
          do: envelope(200, "sync", snapshot(outcome)),
          else: mutation_reply(outcome)
      end)

    values =
      Enum.map(method["params"], &args[&1]) ++
        if(body, do: [body], else: []) ++
        if(method["verb"] == "PUT", do: ["\"before\""], else: [])

    expected = oracle(root, fixture, identity, method["name"], values)
    client = client(fixture, identity)

    opts =
      if body,
        do: [body: Enum.at(expected["normalized_args"], length(method["params"]))],
        else: []

    opts = if method["verb"] == "PUT", do: Keyword.put(opts, :etag, "\"before\""), else: opts
    result = Incus.call(client, method["name"], args, opts)
    assert [%{method: "GET"}, native, local] = HTTPFixture.requests(fixture)
    assert WireComparison.request(native) == WireComparison.request(local)
    assert local.method == method["verb"]
    query = URI.decode_query(URI.parse(local.target).query)
    assert query == %{"project" => "fixture scope", "target" => "member/a"}
    if method["verb"] == "PUT", do: assert(local.headers["if-match"] == "\"before\"")

    check_result(result, expected, client, outcome, {root, fixture, identity})
  end

  defp check_result(result, expected, client, outcome, {root, fixture, identity}) do
    cond do
      outcome in [403, 404, 409, 412] ->
        assert {:error,
                %Error{
                  kind: :native,
                  http_status: ^outcome,
                  error_code: ^outcome,
                  message: message
                }} = result

        assert expected["error_status"] == outcome and expected["error"] == message

      outcome in [:eof, :malformed, :bad_operation] ->
        assert expected["error"]
        assert {:error, %Error{kind: :uncertain, operation: known}} = result
        assert known == if(outcome == :bad_operation, do: @url, else: nil)

      outcome == :sync ->
        refute expected["error"]
        assert {:ok, reply} = result
        assert {reply.type, reply.http_status, reply.operation} == {"sync", 200, ""}
        assert reply.connection == client.connection and reply.identity == :verified

        assert {:error, %Error{kind: :invalid_operation_binding}} =
                 Operation.from_response(client, reply)

      true ->
        refute expected["error"]
        assert {:ok, reply} = result
        assert {reply.type, reply.http_status, reply.operation} == {"async", 202, @url}
        assert {:ok, operation} = Operation.from_response(client, reply)
        assert operation.client == client and operation.url == @url
        assert reply.identity == :verified and reply.connection == client.connection
        refute Operation.completed?(operation)

        assert Map.take(hd(expected["outputs"]), Map.keys(reply.metadata.data)) ==
                 reply.metadata.data

        wait(root, fixture, identity, operation, outcome)
    end
  end

  defp wait(root, fixture, identity, operation, outcome) do
    timeout = if outcome == 103, do: 0, else: 1
    expected = oracle(root, fixture, identity, "GetOperationWait", [@uuid, timeout])

    assert {:ok, reply} =
             Incus.call(operation.client, "GetOperationWait", %{
               "uuid" => @uuid,
               "timeout" => timeout
             })

    assert [%{method: "GET"}, native, local, %{method: "GET"}, native_wait, local_wait] =
             HTTPFixture.requests(fixture)

    assert native.method == local.method
    assert WireComparison.request(native_wait) == WireComparison.request(local_wait)
    assert URI.parse(local_wait.target).path == @url <> "/wait"
    assert reply.etag == Enum.at(expected["outputs"], 1) and reply.etag == "\"lifecycle\""
    assert reply.connection == operation.client.connection and reply.identity == :verified
    assert Map.take(hd(expected["outputs"]), Map.keys(reply.metadata.data)) == reply.metadata.data
    current = %{operation | response: reply}
    assert Operation.completed?(current) == (outcome != 103)
    assert Operation.successful?(current) == (outcome == 200)
    assert reply.metadata.data["err"] == if(outcome == 400, do: "fixture failure", else: "")

    for kind <- [:deadline, :canceled] do
      context = RequestContext.new!(timeout: 30_000)

      context =
        if kind == :deadline,
          do: %{context | deadline: System.monotonic_time(:millisecond) - 1},
          else: context

      if kind == :canceled, do: RequestContext.cancel(context)
      scoped = Incus.with_context(operation.client, context)

      assert {:error, %Error{kind: ^kind}} =
               Incus.call(scoped, "GetOperationWait", %{"uuid" => @uuid, "timeout" => 1})

      assert operation.url == @url and operation.client.connection.request_context == nil
    end

    assert length(HTTPFixture.requests(fixture)) == 6
  end

  defp oracle(root, fixture, identity, name, values) do
    input =
      Map.merge(native_connection(fixture, identity), %{
        action: name,
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

  defp mutation_reply(:eof), do: %{upgrade: fn _, _ -> :ok end}
  defp mutation_reply(:malformed), do: %{status: 200, body: "malformed"}
  defp mutation_reply(:sync), do: envelope(200, "sync", %{})
  defp mutation_reply(:bad_operation), do: envelope(202, "async", %{"status_code" => "bad"})

  defp mutation_reply(code) when code in [403, 404, 409, 412],
    do: %{
      status: code,
      body: %{type: "error", error_code: code, error: "native mutation rejection"}
    }

  defp mutation_reply(_), do: envelope(202, "async", snapshot(103))

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

  defp snapshot(code, may_cancel \\ true),
    do: %{
      "id" => @uuid,
      "status_code" => code,
      "status" => %{103 => "Running", 200 => "Success", 400 => "Failure"}[code],
      "err" => if(code == 400, do: "fixture failure", else: ""),
      "may_cancel" => may_cancel,
      "metadata" => %{"fixture" => "retained"}
    }

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
               do:
                 envelope(200, "sync", %{api_version: "1.0", api_extensions: [], environment: %{}}),
               else: handler.(request)
           end
         ]},
      id: make_ref()
    )
  end

  defp client(fixture, identity) do
    endpoint = HTTPFixture.endpoint(fixture)
    opts = [owner: :fixture, project: "fixture scope", member: "member/a", timeout: 30_000]

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            opts ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, opts)

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
