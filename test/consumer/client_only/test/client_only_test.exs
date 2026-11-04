defmodule ClientOnlyConsumer.Test do
  use ExUnit.Case
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
end
