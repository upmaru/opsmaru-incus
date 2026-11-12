defmodule FoundationConsumer.OperationsTest do
  use ExUnit.Case
  alias Opsmaru.Incus.{Connection, Context, Operations}

  # A host binding: the trusted backend comes from host state, never tool input.
  defmodule IncusHost do
    @behaviour Opsmaru.Incus.Operations.Host

    @impl true
    def binding(%{backend: {connection, context}}, _operation), do: {:ok, connection, context}
    def binding(_caller, _operation), do: {:error, :no_backend}

    @impl true
    def authorize(_caller, _operation, input),
      do: if(Map.get(input, "project", "default") == "default", do: :ok, else: {:error, :project})
  end

  test "the shared catalogue is available to a host without starting anything" do
    names = Enum.map(Operations.all(), & &1.name)
    assert "incus_instance_list" in names and names == Enum.sort(names)
    assert {:ok, %{scope: "incus.read"}} = Operations.fetch("incus_instance_list")
    refute Process.whereis(Opsmaru.Supervisor)
  end

  test "a shared operation runs through the host binding over a private Unix backend" do
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

    caller = %{backend: backend}

    run =
      &Operations.run("incus_instance_list", &1,
        host: IncusHost,
        caller: &2,
        scopes: ["incus.read"]
      )

    assert {:error, %{"kind" => "unauthorized"}} = run.(%{"project" => "other"}, caller)
    refute_receive {:request, _}, 30

    assert {:ok, %{"items" => [%{"name" => "vm1"}], "count" => 1}} = run.(%{}, caller)
    assert_receive {:request, "GET /1.0 HTTP/1.1"}
    assert_receive {:request, "GET /1.0/instances?recursion=1 HTTP/1.1"}

    assert {:error, %{"kind" => "host_binding_failed"}} = run.(%{}, %{})

    assert {:error, %{"kind" => "permission_denied"}} =
             Operations.run("incus_instance_delete", %{"name" => "vm1", "confirm" => "vm1"},
               host: IncusHost,
               caller: caller,
               scopes: ["incus.read"]
             )
  end
end
