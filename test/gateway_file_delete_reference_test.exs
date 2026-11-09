defmodule Opsmaru.Incus.GatewayFileDeleteReferenceTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.TestSupport.HTTPFixture
  @driver Path.expand("../.integration/gateway-file-delete-native", __DIR__)
  @payload :binary.copy(<<0, 255, 128, 13, 10>>, 16_384)
  @path "/tmp/native binary+%.bin"

  setup_all do
    assert Jason.decode!(File.read!(Path.expand("../priv/incus/reference.json", __DIR__)))[
             "revision"
           ] == "13f3992766142d5087fff2e362cd2e1a75294fe8"

    File.mkdir_p!(Path.dirname(@driver))

    {output, status} =
      System.cmd(
        "mise",
        ["exec", "--", "go", "build", "-mod=readonly", "-o", @driver, "./gatewaylive"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    :ok
  end

  for {label, backend_extensions, host_extensions, allowed} <- [
        {"verified and approved", ["instances", "file_delete"], ["instances", "file_delete"],
         true},
        {"not approved by host", ["instances", "file_delete"], ["instances"], false},
        {"not advertised by backend", ["instances"], ["instances", "file_delete"], false}
      ] do
    test "native create/get/delete binary lifecycle: #{label}", context do
      extensions = unquote(backend_extensions)
      stored = start_supervised!({Agent, fn -> nil end})

      backend =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(context.root, "files.sock"),
           handler: fn request ->
             case {request.method, URI.parse(request.target).path} do
               {"GET", "/1.0"} ->
                 sync(%{
                   api_version: "1.0",
                   auth: "trusted",
                   api_extensions: extensions,
                   environment: %{addresses: ["10.0.2.15:8443"], certificate: "private guest"}
                 })

               {"POST", "/1.0/instances/fixture/files"} ->
                 Agent.update(stored, fn _ -> request.body end)
                 sync(%{})

               {"GET", "/1.0/instances/fixture/files"} ->
                 body = Agent.get(stored, & &1)

                 %{
                   raw: [
                     "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\nX-Incus-type: file\r\nX-Incus-mode: 0600\r\nX-Incus-uid: 0\r\nX-Incus-gid: 0\r\n\r\n",
                     body
                   ]
                 }

               {"DELETE", "/1.0/instances/fixture/files"} ->
                 Agent.update(stored, fn _ -> nil end)
                 sync(%{})
             end
           end}
        )

      connection = Connection.unix!(HTTPFixture.endpoint(backend).socket, owner: :fixture)
      server = TLSIdentity.generate(context.root, "file-gateway", "localhost")
      client = TLSIdentity.generate(context.root, "file-client", "file-client")
      {ref, port} = GatewayServer.start_https(server, client.cafile)
      on_exit(fn -> GatewayServer.stop(ref) end)

      mount(context, connection,
        host_config: %{
          authorize: fn request ->
            if request.peer.certificate == client.der and request.project in [nil, "allowed"],
              do: {:ok, :verified},
              else: {:error, :unauthenticated}
          end,
          identity: %{
            origin: "https://gateway.example.com:#{port}",
            addresses: ["gateway.example.com:#{port}"],
            certificate: File.read!(server.certfile),
            connection: connection,
            api_extensions: unquote(host_extensions)
          }
        }
      )

      input = %{
        "Action" => "binary",
        "URL" => "https://localhost:#{port}",
        "ServerCert" => File.read!(server.certfile),
        "ClientCert" => File.read!(client.certfile),
        "ClientKey" => File.read!(client.keyfile),
        "Project" => "allowed",
        "Name" => "fixture",
        "Path" => @path,
        "Data" => Base.encode64(@payload)
      }

      path = Path.join(context.root, "file-input.json")
      File.write!(path, Jason.encode!(input))
      File.chmod!(path, 0o600)
      {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
      assert status == 0, output
      result = Jason.decode!(output)

      if unquote(allowed) do
        assert result["passed"], inspect(Map.take(result, ["error", "error_kind"]))
        assert result["bytes"] == byte_size(@payload)
        assert result["sha256"] == Base.encode16(:crypto.hash(:sha256, @payload), case: :lower)
        assert Agent.get(stored, & &1) == nil
      else
        refute result["passed"]
        assert result["error"] =~ "file_delete"
      end

      requests = HTTPFixture.requests(backend)
      workload = Enum.reject(requests, &(&1.target == "/1.0"))
      expected_methods = if unquote(allowed), do: ["POST", "GET", "DELETE"], else: ["POST", "GET"]
      assert Enum.map(workload, & &1.method) == expected_methods

      assert Enum.all?(
               workload,
               &(&1.target ==
                   "/1.0/instances/fixture/files?path=%2Ftmp%2Fnative+binary%2B%25.bin&project=allowed")
             )

      assert hd(workload).body == @payload
      if unquote(allowed), do: assert(List.last(workload).body == "")
      assert Enum.all?(workload, &(!Map.has_key?(&1.headers, "authorization")))
    end
  end

  defp sync(metadata),
    do: %{status: 200, body: %{type: "sync", status_code: 200, metadata: metadata}}
end
