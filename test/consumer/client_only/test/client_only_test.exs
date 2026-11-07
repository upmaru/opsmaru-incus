defmodule ClientOnlyConsumer.Test do
  use ExUnit.Case
  alias Opsmaru.Incus.Gateway.Identity
  alias Opsmaru.Incus.Operations

  test "the client and operation descriptors work without Plug or an MCP stack" do
    refute Code.ensure_loaded?(TamaMCP.Tool)
    refute Code.ensure_loaded?(Plug.Conn)
    assert Operations.all() != []

    assert {:error, %{"kind" => "host_binding_failed"}} =
             Operations.run("incus_server_get", %{},
               host: nil,
               scopes: ["incus.read"]
             )

    assert Application.spec(:opsmaru_incus, :mod) == []
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
end
