defmodule Opsmaru.Incus.InspectionContractTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, RequestContext, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}

  @names ~w(GetProjects GetProject GetProfiles GetProfile GetNetworks GetNetwork GetStoragePools GetStoragePool GetStoragePoolVolumes GetStoragePoolVolume)
  @methods Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
           |> Enum.filter(&(&1["name"] in @names))
  @extensions ~w(projects network storage)
  @driver Path.expand("../.integration/inspection-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert length(@methods) == 10
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-read-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for method <- @methods, transport <- [:unix, :https] do
    test "#{method["name"]} #{transport} scoped inspection matches native results, routing and errors",
         %{root: root} do
      method = unquote(Macro.escape(method))

      identity =
        if unquote(transport) == :https, do: TLSIdentity.generate(root, "read", "localhost")

      for outcome <- [:populated, :empty, :corrupt, 403, 404],
          do: compare(root, identity, method, outcome)

      bounds(root, identity, method)
      for mode <- [:deadline, :cancel], do: lifetime(root, identity, method, mode)
    end
  end

  defp compare(root, identity, method, outcome) do
    fixture = backend(root, identity, fn _ -> response(method, outcome) end)
    client = client(fixture, identity)
    values = Enum.map(method["params"], &args(method)[&1])

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
    expected = Jason.decode!(out)
    actual = Incus.call(client, method["name"], args(method))
    assert [%{method: "GET"}, native, local] = HTTPFixture.requests(fixture)
    assert local.method == "GET"
    assert WireComparison.request(local) == WireComparison.request(native)
    query = URI.decode_query(URI.parse(local.target).query)
    assert query["project"] == "fixture scope" and query["target"] == "member/a"

    cond do
      is_integer(outcome) ->
        assert {:error,
                %Error{
                  kind: :native,
                  http_status: ^outcome,
                  error_code: ^outcome,
                  response: reply,
                  message: message
                }} = actual

        assert expected["error_status"] == outcome and expected["error"] == message
        assert reply.connection == client.connection and reply.identity == :verified

      outcome == :corrupt ->
        assert expected["error"]
        assert {:error, %Error{kind: :invalid_model}} = actual

      true ->
        refute expected["error"], out
        assert {:ok, reply} = actual
        assert reply.connection == client.connection and reply.identity == :verified
        assert reply.etag == "\"read-etag\""
        if method["result"] == "model", do: assert(reply.etag == Enum.at(expected["outputs"], 1))
        payload = metadata(method, outcome)

        decoded =
          if method["result"] == "list",
            do: Enum.map(reply.metadata, & &1.data),
            else: reply.metadata.data

        assert decoded == payload
        # The native typed DTO drops unknown fields; lossless retention is independent evidence.
        known = fn data -> Map.delete(data, "future_field") end

        if method["result"] == "list" do
          assert Enum.zip(hd(expected["outputs"]), payload)
                 |> Enum.all?(fn {native, data} ->
                   Map.take(native, Map.keys(known.(data))) == known.(data)
                 end)

          assert length(hd(expected["outputs"])) == length(payload)
        else
          assert Map.take(hd(expected["outputs"]), Map.keys(known.(payload))) == known.(payload)
        end
    end
  end

  defp bounds(root, identity, method) do
    fixture = backend(root, identity, fn _ -> response(method, :populated) end)
    client = client(fixture, identity)
    limited = %{client | connection: %{client.connection | max_response_bytes: 32}}

    assert {:error, %Error{kind: :response_limit}} =
             Incus.call(limited, method["name"], args(method))

    for extension <- List.wrap(method["extension"]) do
      missing = %{client | server: %Server{api_extensions: List.delete(@extensions, extension)}}

      assert {:error, %Error{kind: :unsupported_extension}} =
               Incus.call(missing, method["name"], args(method))
    end

    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  defp lifetime(root, identity, method, mode) do
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
    context = RequestContext.new!(timeout: if(mode == :deadline, do: 3_000, else: 30_000))
    scoped = Incus.with_context(original, context)
    task = Task.async(fn -> Incus.call(scoped, method["name"], args(method)) end)
    assert_receive {^tag, :entered}, 10_000
    if mode == :cancel, do: RequestContext.cancel(context)
    kind = if mode == :deadline, do: :deadline, else: :canceled
    assert {:error, %Error{kind: ^kind}} = Task.await(task, 10_000)
    assert_receive {^tag, :closed, {:error, :closed}}, 10_000
    assert original.connection.request_context == nil
    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  defp response(_method, code) when is_integer(code),
    do: %{status: code, body: %{type: "error", error_code: code, error: "native read rejection"}}

  defp response(method, outcome),
    do: %{
      status: 200,
      headers: %{"ETag" => "\"read-etag\""},
      body: %{type: "sync", status_code: 200, metadata: metadata(method, outcome)}
    }

  defp metadata(%{"result" => "list"}, :empty), do: []
  defp metadata(_, :empty), do: %{}

  defp metadata(method, outcome) do
    data = if outcome == :corrupt, do: %{"config" => []}, else: sample(method["model"])
    if method["result"] == "list", do: [data], else: data
  end

  defp sample(model) do
    base = %{
      "name" => "fixture",
      "description" => "inspection",
      "config" => %{"user.note" => "value"},
      "used_by" => [],
      "future_field" => %{}
    }

    case model do
      "Profile" ->
        Map.put(base, "devices", %{
          "root" => %{"type" => "disk", "path" => "/", "pool" => "fixture"}
        })

      "Network" ->
        Map.merge(base, %{"type" => "bridge", "managed" => true, "locations" => ["member-a"]})

      "StoragePool" ->
        Map.merge(base, %{"driver" => "dir", "status" => "Created", "locations" => ["member-a"]})

      "StorageVolume" ->
        Map.merge(base, %{
          "type" => "custom",
          "content_type" => "filesystem",
          "project" => "fixture scope",
          "location" => "member-a"
        })

      "Project" ->
        base
    end
  end

  defp args(method),
    do:
      Map.new(method["params"], &{&1, if(&1 == "volType", do: "custom", else: "fixture-" <> &1)})

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
