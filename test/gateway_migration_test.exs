defmodule Opsmaru.Incus.GatewayMigrationTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.TestSupport.NativeMigrationBackend, as: Backend

  defmodule Host do
    @behaviour Opsmaru.Incus.Gateway.Host
    def ready?(_), do: true

    def authorize(request, config) do
      if request.peer.certificate == config.client.der and
           request.project in [nil, "migration-project"],
         do: {:ok, :caller},
         else: {:error, :unauthenticated}
    end

    def identity(_, config), do: {:ok, config.identity}
    def valid?(_, grant, _), do: grant in [:caller, :pending_migration]

    def admit_operation_secret(request, config) do
      send(config.observer, {:server_admission, config.name, request})
      # Operation ownership comes from the host's verified pending migration,
      # even when the pinned native WebSocket helper omits its project query.
      if request.operation == config.name and request.project in [nil, "migration-project"] and
           request.target == nil and request.peer.address == {127, 0, 0, 1} do
        {:ok, :pending_migration}
      else
        {:error, :forbidden}
      end
    end
  end

  setup_all do
    Backend.build!()
    :ok
  end

  for kind <- [:instance, :snapshot], mode <- [:relay, :pull, :push] do
    test "pinned #{kind} #{mode} crosses source and target gateways with public endpoint identity",
         context do
      log = start_supervised!({Agent, fn -> [] end})
      source = Backend.start(context, "source", log: log)
      target = Backend.start(context, "target", log: log)
      source_endpoint = mounted(context, source)
      target_endpoint = mounted(context, target)

      result =
        Backend.run(context.root, %{
          Action: unquote(kind),
          Mode: unquote(mode),
          Parent: "source",
          Body: Backend.model(unquote(kind)),
          Source: source_endpoint,
          Target: target_endpoint
        })

      assert result["completed"], inspect(Map.take(result, ["error", "accepted"]))
      assert result["source_info"]["URL"] == source_endpoint[:URL]
      assert result["target_info"]["URL"] == target_endpoint[:URL]

      for {key, endpoint} <- [{"source_info", source_endpoint}, {"target_info", target_endpoint}] do
        assert result[key]["Certificate"] == endpoint[:Certificate]

        assert result[key]["Addresses"] == [
                 endpoint[:URL],
                 "https://gateway.example.com:#{URI.parse(endpoint[:URL]).port}"
               ]

        refute inspect(result[key]) =~ "10.0.2.15"
        refute inspect(result[key]) =~ "127.0.0.1:9"
      end

      for side <- [source, target] do
        assert Enum.count(Backend.requests(side), &(&1.method == "POST")) == 1
        refute Enum.any?(Backend.requests(side), &(&1.method == "DELETE"))
      end

      verify_channels(unquote(mode), Backend.events(source), source_endpoint, target_endpoint)
    end
  end

  for mode <- [:pull, :push] do
    test "#{mode} preserves guest-side reachability failure without a guest fallback", context do
      log = start_supervised!({Agent, fn -> [] end})
      error = "guest network cannot reach peer"

      source =
        Backend.start(context, "source", log: log, failure: if(unquote(mode) == :push, do: error))

      target =
        Backend.start(context, "target", log: log, failure: if(unquote(mode) == :pull, do: error))

      result =
        Backend.run(context.root, %{
          Action: "instance",
          Mode: unquote(mode),
          Body: Backend.model(:instance),
          Source: mounted(context, source),
          Target: mounted(context, target)
        })

      assert result["error"] =~ error
      refute Enum.any?(Backend.events(source), &match?({:outbound, _, _, _}, &1))
      # The pinned client owns its multi-address retry/cancel behavior. The
      # gateway itself never dials the guest-advertised environment addresses.
      refute_received {:server_admission, _, _}
    end
  end

  defp verify_channels(mode, events, source_endpoint, target_endpoint) do
    frames = for {:frame, name, channel, data} <- events, do: {name, channel, data}

    assert frames != [], inspect(Enum.filter(events, &match?({:outbound, _, _, _}, &1)))

    case mode do
      :relay ->
        assert Enum.sort(frames) ==
                 Enum.sort(
                   for name <- ~w(source target),
                       channel <- ~w(control fs),
                       do: {name, channel, other(name) <> ":" <> channel}
                 )

        refute_received {:server_admission, _, _}

      mode ->
        inbound = inbound(mode)
        outbound = other(inbound)

        assert Enum.sort(frames) ==
                 Enum.sort(
                   for channel <- ~w(control fs),
                       do: {inbound, channel, outbound <> ":" <> channel}
                 )

        assert [{:outbound, ^outbound, operation, output}] =
                 Enum.filter(events, &match?({:outbound, _, _, _}, &1))

        assert operation ==
                 if(mode == :pull, do: source_endpoint[:URL], else: target_endpoint[:URL]) <>
                   "/1.0/operations/" <> inbound

        assert output["frames"] == Map.new(~w(control fs), &{&1, inbound <> ":" <> &1})

        for _ <- 1..2 do
          assert_received {:server_admission, ^inbound, request}
          assert request.project == nil
          assert request.peer.certificate == nil
          assert request.operation == inbound
        end
    end
  end

  defp inbound(:pull), do: "source"
  defp inbound(:push), do: "target"

  defp other("source"), do: "target"
  defp other("target"), do: "source"

  defp mounted(context, side) do
    server = TLSIdentity.generate(context.root, "front-#{side.name}", "localhost")
    client = TLSIdentity.generate(context.root, "client-#{side.name}", "caller")
    {ref, port} = GatewayServer.start_https(server, client.cafile)
    on_exit(fn -> GatewayServer.stop(ref) end)

    gateway =
      Gateway.new!(
        connection: side.connection,
        host: Host,
        admission: context.admission,
        host_config: %{
          observer: self(),
          name: side.name,
          client: client,
          identity: %{
            origin: "https://gateway.example.com:#{port}",
            addresses: ["gateway.example.com:#{port}"],
            certificate: File.read!(server.certfile),
            connection: side.connection,
            api_extensions: Backend.extensions()
          }
        }
      )

    GatewayServer.put_gateway(gateway, port)

    %{
      URL: "https://localhost:#{port}",
      Certificate: File.read!(server.certfile),
      ClientCertificate: File.read!(client.certfile),
      ClientKey: File.read!(client.keyfile),
      Project: "migration-project"
    }
  end
end
