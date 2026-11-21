defmodule Opsmaru.Incus.GatewayInstanceLaunchReferenceTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.TestSupport.HTTPFixture
  @driver Path.expand("../.integration/gateway-instance-launch-native", __DIR__)
  @operation "6e5e9d8c-3a0f-4d4b-9a51-0c1f5b1f7a10"
  @restart "0b8f7f3e-52f4-4f0c-8f0f-6b7a3c2f9d21"

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
        {"verified and approved", ["instances", "instance_create_start"],
         ["instances", "instance_create_start"], true},
        {"not approved by host", ["instances", "instance_create_start"], ["instances"], false},
        {"not advertised by backend", ["instances"], ["instances", "instance_create_start"],
         false}
      ] do
    test "native instance launch: #{label}", context do
      extensions = unquote(backend_extensions)
      # A backend with instance_create_start honours `start` in the create
      # body; one without it ignores the field, as the pinned client assumes.
      honours_start = "instance_create_start" in extensions
      running = start_supervised!({Agent, fn -> false end})

      backend =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(context.root, "launch.sock"),
           handler: fn request ->
             case {request.method, URI.parse(request.target).path} do
               {"GET", "/1.0"} ->
                 sync(%{
                   api_version: "1.0",
                   auth: "trusted",
                   api_extensions: extensions,
                   environment: %{addresses: ["10.0.2.15:8443"], certificate: "private guest"}
                 })

               {"POST", "/1.0/instances"} ->
                 if honours_start and Jason.decode!(request.body)["start"] == true,
                   do: Agent.update(running, fn _ -> true end)

                 async(@operation)

               {"GET", "/1.0/operations/" <> rest} ->
                 [id, "wait"] = String.split(rest, "/")
                 sync(operation(id, 200))

               {"PUT", "/1.0/instances/c1/state"} ->
                 if Agent.get_and_update(running, &{&1, true}) do
                   %{
                     status: 400,
                     body: %{
                       type: "error",
                       error_code: 400,
                       error: "The instance is already running"
                     }
                   }
                 else
                   async(@restart)
                 end
             end
           end}
        )

      connection = Connection.unix!(HTTPFixture.endpoint(backend).socket, owner: :fixture)
      server = TLSIdentity.generate(context.root, "launch-gateway", "localhost")
      client = TLSIdentity.generate(context.root, "launch-client", "launch-client")
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
        "Action" => "launch",
        "URL" => "https://localhost:#{port}",
        "ServerCert" => File.read!(server.certfile),
        "ClientCert" => File.read!(client.certfile),
        "ClientKey" => File.read!(client.keyfile),
        "Project" => "allowed",
        "Name" => "c1"
      }

      path = Path.join(context.root, "launch-input.json")
      File.write!(path, Jason.encode!(input))
      File.chmod!(path, 0o600)
      {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
      assert status == 0, output
      result = Jason.decode!(output)

      requests = HTTPFixture.requests(backend)
      assert Enum.all?(requests, &(!Map.has_key?(&1.headers, "authorization")))
      workload = Enum.reject(requests, &(&1.target == "/1.0"))
      [create | rest] = workload

      # The create body reaches the backend with `start: true` whatever the
      # gateway advertises.
      assert {create.method, create.target} == {"POST", "/1.0/instances?project=allowed"}
      assert %{"name" => "c1", "start" => true} = Jason.decode!(create.body)
      starts = Enum.filter(rest, &(&1.method == "PUT"))

      case unquote({allowed, "instance_create_start" in backend_extensions}) do
        {true, _} ->
          # One create, one wait and no second start.
          assert result["passed"], inspect(Map.take(result, ["error", "error_kind"]))
          assert result["server_started"]
          refute result["second_start"]
          assert starts == []

          assert Enum.map(rest, &{&1.method, URI.parse(&1.target).path}) == [
                   {"GET", "/1.0/operations/#{@operation}/wait"}
                 ]

          assert Agent.get(running, & &1)

        {false, true} ->
          # The backend started the instance, but the host withheld the
          # advertisement, so the client issues its own start and is refused.
          refute result["passed"]
          assert result["second_start"]
          assert result["error"] =~ "already running"
          assert [%{target: "/1.0/instances/c1/state?project=allowed"}] = starts

        {false, false} ->
          # A backend without the extension ignores `start`, and the client's
          # own start is the one that takes effect.
          assert result["passed"], inspect(Map.take(result, ["error", "error_kind"]))
          refute result["server_started"]
          assert result["second_start"]
          assert [%{target: "/1.0/instances/c1/state?project=allowed"} = start] = starts
          assert %{"action" => "start"} = Jason.decode!(start.body)
          assert Agent.get(running, & &1)
      end
    end
  end

  defp operation(id, status_code),
    do: %{
      "id" => id,
      "class" => "task",
      "status" => if(status_code == 200, do: "Success", else: "Running"),
      "status_code" => status_code,
      "resources" => %{"instances" => ["/1.0/instances/c1"]},
      "metadata" => %{},
      "may_cancel" => false,
      "err" => ""
    }

  defp async(id),
    do: %{
      status: 202,
      headers: %{"Location" => "/1.0/operations/#{id}"},
      body: %{
        type: "async",
        status: "Operation created",
        status_code: 100,
        operation: "/1.0/operations/#{id}",
        metadata: operation(id, 103)
      }
    }

  defp sync(metadata),
    do: %{status: 200, body: %{type: "sync", status_code: 200, metadata: metadata}}
end
