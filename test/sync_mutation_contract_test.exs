defmodule Opsmaru.Incus.SyncMutationContractTest do
  @moduledoc "B09 synchronous write contracts compared with the named pinned Go methods."
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, ModelSamples, TLSIdentity, WireComparison}
  @driver Path.expand("../.integration/sync-mutation-driver", __DIR__)

  # B09 PR 2: every synchronous network write (create, rename, update, delete).
  @names ~w(CreateNetwork RenameNetwork UpdateNetwork DeleteNetwork CreateNetworkACL RenameNetworkACL UpdateNetworkACL DeleteNetworkACL CreateNetworkAddressSet RenameNetworkAddressSet UpdateNetworkAddressSet DeleteNetworkAddressSet CreateNetworkIntegration RenameNetworkIntegration UpdateNetworkIntegration DeleteNetworkIntegration CreateNetworkZone UpdateNetworkZone DeleteNetworkZone CreateNetworkZoneRecord UpdateNetworkZoneRecord DeleteNetworkZoneRecord CreateNetworkForward UpdateNetworkForward DeleteNetworkForward CreateNetworkLoadBalancer UpdateNetworkLoadBalancer DeleteNetworkLoadBalancer CreateNetworkPeer UpdateNetworkPeer DeleteNetworkPeer)
  @methods Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
           |> Enum.filter(&(&1["name"] in @names))
  @extensions ~w(network network_acl network_address_set network_integrations network_dns network_dns_records network_forward network_load_balancer network_peer)
  @etag "\"before\""

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert length(@methods) == 31
    assert Enum.all?(@methods, &(&1["result"] == "sync"))
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-sync-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for method <- @methods, transport <- [:unix, :https] do
    test "#{method["name"]} #{transport} synchronous write matches native request, result and rejection",
         %{root: root} do
      method = unquote(Macro.escape(method))
      identity = identity(root, unquote(transport))

      for outcome <- [:sync, 400, 403, 404, 409, 412, :eof, :malformed],
          do: compare(root, identity, method, outcome)

      preflight(root, identity, method)
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

  defp compare(root, identity, method, outcome) do
    fixture = backend(root, identity, fn _ -> reply(outcome) end)
    body = body(method)
    expected = oracle(root, fixture, identity, method, args(method), body)
    client = client(fixture, identity, @extensions)
    actual = call(client, method, normalized(expected, method, body))
    assert [%{method: "GET"}, native, local] = HTTPFixture.requests(fixture)
    assert local.method == method["verb"]
    assert WireComparison.request(native) == WireComparison.request(local)
    query = URI.decode_query(URI.parse(local.target).query || "")
    assert query == %{"project" => "fixture scope", "target" => "member/a"}
    if method["verb"] == "PUT", do: assert(local.headers["if-match"] == @etag)

    case outcome do
      :sync ->
        refute expected["error"]
        assert {:ok, reply} = actual
        assert {reply.type, reply.http_status} == {"sync", 200}
        assert reply.connection == client.connection and reply.identity == :verified

      code when is_integer(code) ->
        assert {:error,
                %Error{kind: :native, http_status: ^code, error_code: ^code, message: message}} =
                 actual

        assert expected["error_status"] == code and expected["error"] == message

      # A dispatched write whose reply is lost or malformed may have taken effect.
      lost when lost in [:eof, :malformed] ->
        assert expected["error"]
        assert {:error, %Error{kind: :uncertain}} = actual
    end
  end

  # Invalid input, unready hosts and missing extensions reject before any I/O.
  defp preflight(root, identity, method) do
    fixture = backend(root, identity, fn _ -> flunk("preflight write was dispatched") end)
    client = client(fixture, identity, @extensions)

    if method["body"] do
      [{field, _} | _] = Enum.sort(body(method))
      invalid = Map.put(body(method), field, %{"invalid" => self()})

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

  defp body(%{"body" => model}), do: ModelSamples.generate(model)

  defp args(method), do: Map.new(method["params"], &{&1, "fixture /" <> &1})

  defp oracle(root, fixture, identity, method, args, body) do
    values =
      Enum.map(method["params"], &args[&1]) ++
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

  defp reply(:eof), do: %{upgrade: fn _, _ -> :ok end}
  defp reply(:malformed), do: %{status: 200, body: "malformed"}

  defp reply(code),
    do: %{status: code, body: %{type: "error", error_code: code, error: "native write rejection"}}

  defp identity(_root, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "sync-#{System.unique_integer([:positive])}", "localhost")

  defp backend(root, identity, handler, extensions \\ @extensions) do
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
                   metadata: %{api_version: "1.0", api_extensions: extensions, environment: %{}}
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
