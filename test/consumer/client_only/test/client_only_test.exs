defmodule ClientOnlyConsumer.Test do
  use ExUnit.Case
  alias Opsmaru.Incus.Connection
  alias Opsmaru.Incus.Gateway.{Exchange, Identity}
  alias Opsmaru.Incus.Operations.{Composite, Native}
  alias Opsmaru.Incus.Telemetry

  test "the client and operation descriptors work without Plug or an MCP stack" do
    refute Code.ensure_loaded?(TamaMCP.Tool)
    refute Code.ensure_loaded?(Plug.Conn)
    assert Composite.all() != []

    assert {:error, %{"kind" => "host_binding_failed"}} =
             Composite.run("incus_server_get", %{},
               host: nil,
               scopes: ["incus.read"]
             )

    assert Application.spec(:opsmaru_incus, :mod) == []
    refute Code.ensure_loaded?(NimblePool)
    refute Code.ensure_loaded?(Opsmaru.Incus.ConnectionPool)
    refute Process.whereis(NimblePool.TaskSupervisor)

    assert_raise ArgumentError, ~r/optional connection pool/, fn ->
      Connection.unix!("/private/consumer-fixture.sock",
        owner: :consumer,
        pool: :missing
      )
    end
  end

  test "both operation documents build from the package without tama_dex or the upstream YAML" do
    refute Code.ensure_loaded?(Tama.Dex)
    refute File.exists?(Application.app_dir(:opsmaru_incus, "priv/incus/rest-api.yaml"))
    version = to_string(Application.spec(:opsmaru_incus, :vsn))

    for {builder, source, prefix} <- [
          {&Composite.openapi/0, "opsmaru_incus", "incus_"},
          {&Native.openapi/0, "opsmaru_incus_native", "incus_native_"}
        ] do
      document = builder.()
      assert document["x-tama-profile"] == "tama-operations/1"
      assert document["x-tama-source"] == source
      assert document["info"]["version"] == version
      assert map_size(document["paths"]) > 0
      assert document == builder.()
      assert document == document |> Jason.encode!() |> Jason.decode!()

      for {path, %{"post" => operation}} <- document["paths"] do
        assert path == "/operations/" <> operation["operationId"]
        assert String.starts_with?(operation["operationId"], prefix)
      end
    end

    assert map_size(Composite.openapi()["paths"]) == length(Composite.all())
    assert Enum.any?(Native.unavailable(), &(&1["method"] == "ExecInstance"))

    assert {:error, %{"kind" => "permission_denied"}} =
             Native.run("incus_native_get_instances", %{"instance_type" => ""},
               host: nil,
               scopes: Composite.scopes()
             )

    assert {:error, %{"kind" => "host_binding_failed"}} =
             Native.run("incus_native_get_instances", %{"instance_type" => ""},
               host: nil,
               scopes: Native.scopes()
             )
  end

  test "gateway configuration is available but its web adapters are not compiled" do
    refute Code.ensure_loaded?(Plug.Conn)
    refute Code.ensure_loaded?(:cowboy_req)
    assert Code.ensure_loaded?(Opsmaru.Incus.Gateway)
    assert Code.ensure_loaded?(Opsmaru.Incus.Gateway.Policy)
    refute Code.ensure_loaded?(Opsmaru.Incus.Gateway.Plug)
    refute Code.ensure_loaded?(Opsmaru.Incus.Gateway.HTTPRelay)
    refute Code.ensure_loaded?(Opsmaru.Incus.Gateway.WebSocket)
    refute Code.ensure_loaded?(Opsmaru.Incus.Gateway.WebSocketRelay)
    refute Code.ensure_loaded?(Opsmaru.Incus.Gateway.CowboyHandler)
    refute Code.ensure_loaded?(Opsmaru.Incus.Gateway.RawRelay)
    refute Code.ensure_loaded?(Opsmaru.Incus.Gateway.RawTunnel)
    refute "console" in Identity.supported_extensions()
  end

  test "gateway telemetry compiles to a no-op without the optional dependency" do
    refute Code.ensure_loaded?(:telemetry)
    refute Map.has_key?(Mix.Project.deps_paths(), :telemetry)
    assert Telemetry.list_handlers([:opsmaru_incus]) == []
    assert Telemetry.execute([:opsmaru_incus, :gateway], %{}, %{}) == :ok

    exchange =
      Exchange.start(%{host: nil, protocol: :http, method: "GET", peer: %{}})

    refute Exchange.active?(exchange)
  end

  test "relayed HTTP extensions are advertised while WebSocket-gated ones are not" do
    supported = Identity.supported_extensions()

    assert "projects" in supported
    refute "console_force" in supported
    refute "storage_api_remote_volume_snapshot_copy" in supported
  end
end
