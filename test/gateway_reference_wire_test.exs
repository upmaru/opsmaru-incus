defmodule Opsmaru.Incus.GatewayReferenceWireTest do
  # Task 3.1 differential: the unmodified pinned Incus v7.0.1 Go client, run
  # through a mutual-TLS gateway listener, gets the same results the recorded
  # wire fixtures expect, and the backend receives the recorded request.
  # The direct (no gateway) baseline is test/reference_wire_test.exs.
  use Opsmaru.TestSupport.GatewayCase, async: false

  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}

  @fixtures Path.expand("fixtures/incus/wire.json", __DIR__)
  # Its own binary, so it never races the direct wire test building the same driver.
  @driver Path.expand("../.integration/incus-reference-driver-gateway", __DIR__)
  @reference_dir Path.expand("reference", __DIR__)

  setup_all do
    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: @reference_dir,
        stderr_to_stdout: true,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    assert status == 0, output
    :ok
  end

  test "pinned official client agrees with wire fixtures through the gateway", context do
    server = TLSIdentity.generate(context.root, "gateway", "localhost")
    client = TLSIdentity.generate(context.root, "incus-client", "incus-client")
    {ref, port} = GatewayServer.start_https(server, client.cafile)
    on_exit(fn -> GatewayServer.stop(ref) end)

    fixtures = Jason.decode!(File.read!(@fixtures))
    assert fixtures["reference_revision"] == "13f3992766142d5087fff2e362cd2e1a75294fe8"

    for {fixture, index} <- Enum.with_index(fixtures["cases"]) do
      reply = fixture["reply"]
      response = %{status: reply["status"], headers: reply["headers"], body: reply["body"]}

      backend =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(context.root, "wire-#{index}.sock"),
           handler: fn _ -> response end},
          id: {:wire, index}
        )

      certificate = client.der

      mount(context, Connection.unix!(HTTPFixture.endpoint(backend).socket, owner: :fixture),
        host_config: %{
          authorize: fn request ->
            if request.peer.certificate == certificate,
              do: {:ok, :certificate},
              else: {:error, :unauthenticated}
          end
        }
      )

      input =
        Map.merge(fixture["input"], %{
          "url" => "https://localhost:#{port}",
          "server_cert" => File.read!(server.certfile),
          "client_cert" => File.read!(client.certfile),
          "client_key" => File.read!(client.keyfile)
        })

      input_path = Path.join(context.root, "wire-input-#{index}.json")
      File.write!(input_path, Jason.encode!(input))
      File.chmod!(input_path, 0o600)
      {output, status} = System.cmd(@driver, [input_path], stderr_to_stdout: true)
      assert status == 0, output

      assert :ok == WireComparison.compare(fixture["result"], Jason.decode!(output)),
             fixture["name"]

      assert [request] = HTTPFixture.requests(backend)
      assert :ok == WireComparison.compare(fixture["request"], WireComparison.request(request))
      assert_received {:host_authorize, %{peer: %{certificate: ^certificate}}}
      stop_supervised!({:wire, index})
    end
  end
end
