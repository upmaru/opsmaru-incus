defmodule Opsmaru.Incus.GatewayInstanceListReferenceTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.TestSupport.HTTPFixture
  @driver Path.expand("../.integration/gateway-instance-list-native", __DIR__)

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
        {"verified and approved", ["instances", "api_filtering", "instance_get_full"],
         ["instances", "api_filtering", "instance_get_full"], true},
        {"not approved by host", ["instances", "api_filtering", "instance_get_full"],
         ["instances"], false},
        {"not advertised by backend", ["instances"],
         ["instances", "api_filtering", "instance_get_full"], false},
        {"filtering approved but the full read is not", ["instances", "api_filtering"],
         ["instances", "api_filtering"], false}
      ] do
    test "native instance list with default columns: #{label}", context do
      extensions = unquote(backend_extensions)

      backend =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(context.root, "list.sock"),
           handler: fn request ->
             path = URI.parse(request.target).path

             case {request.method, path} do
               {"GET", "/1.0"} ->
                 sync(%{
                   api_version: "1.0",
                   auth: "trusted",
                   api_extensions: extensions,
                   environment: %{addresses: ["10.0.2.15:8443"], certificate: "private guest"}
                 })

               {"GET", "/1.0/instances"} ->
                 sync([
                   %{"name" => "alpha", "type" => "container", "status" => "Running"},
                   %{"name" => "beta", "type" => "container", "status" => "Stopped"}
                 ])

               {"GET", "/1.0/instances/alpha"} ->
                 sync(instance("alpha", "Running"))

               {"GET", "/1.0/instances/beta"} ->
                 sync(instance("beta", "Stopped"))

               {"GET", "/1.0/instances/alpha/state"} ->
                 sync(%{"status" => "Running"})

               {"GET", "/1.0/instances/beta/state"} ->
                 sync(%{"status" => "Stopped"})

               {"GET", "/1.0/instances/alpha/snapshots"} ->
                 sync([])

               {"GET", "/1.0/instances/beta/snapshots"} ->
                 sync([])
             end
           end}
        )

      connection = Connection.unix!(HTTPFixture.endpoint(backend).socket, owner: :fixture)
      server = TLSIdentity.generate(context.root, "list-gateway", "localhost")
      client = TLSIdentity.generate(context.root, "list-client", "list-client")
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
        "Action" => "list",
        "URL" => "https://localhost:#{port}",
        "ServerCert" => File.read!(server.certfile),
        "ClientCert" => File.read!(client.certfile),
        "ClientKey" => File.read!(client.keyfile),
        "Project" => "allowed",
        "ListFilters" => ["name=fixture"]
      }

      path = Path.join(context.root, "list-input.json")
      File.write!(path, Jason.encode!(input))
      File.chmod!(path, 0o600)
      {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
      assert status == 0, output
      result = Jason.decode!(output)

      requests = HTTPFixture.requests(backend)
      assert Enum.all?(requests, &(!Map.has_key?(&1.headers, "authorization")))
      workload = Enum.reject(requests, &(&1.target == "/1.0"))

      case unquote({
             allowed,
             Enum.member?(backend_extensions, "api_filtering") and
               Enum.member?(host_extensions, "api_filtering")
           }) do
        {true, _} ->
          assert result["passed"], inspect(Map.take(result, ["error", "error_kind"]))
          assert result["instances"] == ["alpha", "beta"]
          assert result["full"]["alpha"]["status"] == "Running"
          assert result["full"]["alpha"]["snapshots"] == 0
          assert result["full"]["beta"]["status"] == "Stopped"
          assert result["full"]["beta"]["snapshots"] == 0

          # The filtered collection read and one full read per instance, with
          # the filter and project queries forwarded byte for byte.
          assert Enum.map(workload, & &1.target) == [
                   "/1.0/instances?filter=name+eq+fixture&project=allowed&recursion=1",
                   "/1.0/instances/alpha?project=allowed&recursion=1",
                   "/1.0/instances/beta?project=allowed&recursion=1"
                 ]

        {false, true} ->
          # api_filtering alone still lists, but the full read falls back to
          # state and snapshots, which stops at the missing container_backup.
          refute result["passed"]
          assert result["error"] =~ "container_backup"
          assert result["instances"] == ["alpha", "beta"]

          assert Enum.map(workload, & &1.target) == [
                   "/1.0/instances?filter=name+eq+fixture&project=allowed&recursion=1",
                   "/1.0/instances/alpha?project=allowed",
                   "/1.0/instances/alpha/state?project=allowed",
                   "/1.0/instances/alpha/snapshots?project=allowed&recursion=1"
                 ]

          refute Enum.any?(workload, &String.contains?(&1.target, "/backups"))

        {false, false} ->
          # The client refuses before any instance request is issued.
          refute result["passed"]
          assert result["error"] =~ "api_filtering"
          assert Enum.map(requests, & &1.target) == ["/1.0"]
      end
    end
  end

  defp instance(name, status),
    do: %{
      "name" => name,
      "type" => "container",
      "status" => status,
      "state" => %{"status" => status}
    }

  defp sync(metadata),
    do: %{status: 200, body: %{type: "sync", status_code: 200, metadata: metadata}}
end
