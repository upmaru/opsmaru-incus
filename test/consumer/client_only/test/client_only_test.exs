defmodule ClientOnlyConsumer.Test do
  use ExUnit.Case
  alias Opsmaru.Incus.MCP.Tools
  alias Opsmaru.Incus.Operations

  test "the client and operation descriptors work without tama_mcp" do
    refute Code.ensure_loaded?(TamaMCP.Tool)
    refute Code.ensure_loaded?(Plug.Conn)
    refute Code.ensure_loaded?(Tools)
    refute Code.ensure_loaded?(Tools.InstanceList)
    assert Operations.all() != []

    assert {:error, %{"kind" => "host_binding_failed"}} =
             Operations.run("incus_server_get", %{},
               host: nil,
               scopes: ["incus.read"]
             )

    assert Application.spec(:opsmaru_incus, :mod) == []
  end
end
