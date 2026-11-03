defmodule FoundationConsumer.OperationsTest do
  use ExUnit.Case
  alias Opsmaru.Incus.{Connection, Context, Operations}
  alias Opsmaru.Incus.MCP.Tools

  test "shared Incus tools compose with host tools in one host server" do
    shared = Enum.map(Tools.all(), &elem(&1, 0))
    assert shared == Enum.map(Operations.all(), & &1.name)
    assert FoundationConsumer.MCP.tool_names() == Enum.sort(["consumer_runtime_status" | shared])
    module = FoundationConsumer.MCP.tool("incus_instance_list")
    assert module.task_policy() == :disabled and module.scopes() == ["incus.read"]
    refute Process.whereis(Opsmaru.Supervisor)
  end

  test "a shared tool runs through the host binding over a private Unix backend" do
    root = Path.join(System.tmp_dir!(), "op-consumer-ops-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "incus.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    serve = fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 5_000)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
      send(parent, {:request, hd(String.split(request, "\r\n"))})

      metadata =
        if request =~ "GET /1.0/instances",
          do: [%{"name" => "vm1", "type" => "virtual-machine"}],
          else: %{"api_version" => "1.0", "api_extensions" => [], "environment" => %{}}

      body = Jason.encode!(%{type: "sync", status_code: 200, metadata: metadata})

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\nContent-Length: ",
          Integer.to_string(byte_size(body)),
          "\r\n\r\n",
          body
        ])

      :gen_tcp.close(socket)
    end

    worker =
      spawn_link(fn ->
        serve.()
        serve.()
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    backend =
      {Connection.unix!(path, owner: :consumer),
       Context.new!(owner: :consumer, identity: :verified, ready?: fn -> true end)}

    context = %TamaMCP.Context{
      scopes: ["incus.read"],
      assigns: %{opsmaru_incus_host: FoundationConsumer.IncusHost, backend: backend}
    }

    module = FoundationConsumer.MCP.tool("incus_instance_list")

    assert {:ok, %TamaMCP.Response{is_error: true}} =
             module.call(%{"project" => "other"}, context)

    refute_receive {:request, _}, 30

    assert {:ok,
            %TamaMCP.Response{
              is_error: false,
              structured_content: %{"items" => [%{"name" => "vm1"}]}
            }} =
             module.call(%{}, context)

    assert_receive {:request, "GET /1.0 HTTP/1.1"}
    assert_receive {:request, "GET /1.0/instances?recursion=1 HTTP/1.1"}

    assert {:ok,
            %TamaMCP.Response{
              is_error: true,
              structured_content: %{"error" => %{"kind" => "host_binding_failed"}}
            }} =
             module.call(%{}, %{context | assigns: %{}})
  end
end
