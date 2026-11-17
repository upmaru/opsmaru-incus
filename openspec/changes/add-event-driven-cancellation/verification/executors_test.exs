defmodule Opsmaru.Incus.ExecutorCancellationTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, ConnectionPool, RequestContext, Server}
  alias Opsmaru.Incus.Operations.{Composite, Native}
  alias Opsmaru.TestSupport.{OperationsFixture, OperationsHost}

  @timeout 5_000
  @held "/1.0/instances/held"
  @ready "/1.0/instances/ready"
  @query %{"project" => "tenant", "target" => "member"}

  for {executor, get, delete} <- [
        {Composite, "incus_instance_get", "incus_instance_delete"},
        {Native, "incus_native_get_instance", "incus_native_delete_instance"}
      ],
      transport <- [:gen_tcp, :ssl] do
    @tag executor: executor, get: get, delete: delete, transport: transport
    test "#{inspect(executor)} preserves bound cancellation and dispatch results over #{transport}",
         %{executor: executor, get: get, delete: delete, transport: transport} do
      root = OperationsFixture.root()
      on_exit(fn -> File.rm_rf!(root) end)
      pool = if transport == :ssl, do: start_supervised!({ConnectionPool, size: 1})
      opts = if pool, do: [connection: [pool: pool]], else: []
      fixture = OperationsFixture.start(root, transport, routes(self()), opts)
      connection = Connection.member(fixture.connection, "member")
      input = %{"name" => "held", "project" => "tenant"}

      denied = %{binding: {connection, fixture.context}, authorize: fn _, _ -> :forbidden end}
      assert {:error, %{"kind" => "unauthorized"}} = run(executor, get, input, denied)

      context = RequestContext.new!(timeout: 20_000)
      assert :ok = RequestContext.cancel(context)
      canceled = %{binding: {Connection.with_context(connection, context), fixture.context}}
      assert {:error, %{"kind" => "canceled"}} = run(executor, get, input, canceled)
      assert OperationsFixture.requests(fixture) == []
      if pool, do: assert(:sys.get_state(pool).bindings == %{})

      context = RequestContext.new!(timeout: 20_000)
      bound = %{binding: {Connection.with_context(connection, context), fixture.context}}
      read = Task.async(fn -> run(executor, get, input, bound) end)
      assert_receive {:held, "GET", target}, @timeout
      assert OperationsFixture.query(%{target: target}) == @query
      if pool, do: assert(map_size(:sys.get_state(pool).bindings) == 1)
      assert :ok = RequestContext.cancel(context)
      assert {:error, %{"kind" => "canceled"}} = Task.await(read, @timeout)
      assert_receive {:peer, "GET", {:error, :closed}}, @timeout

      context = RequestContext.new!(timeout: 20_000)
      bound = %{binding: client(fixture, Connection.with_context(connection, context))}

      mutation =
        Task.async(fn -> run(executor, delete, Map.put(input, "confirm", "held"), bound) end)

      assert_receive {:held, "DELETE", target}, @timeout
      assert OperationsFixture.query(%{target: target}) == @query
      assert :ok = RequestContext.cancel(context)
      assert_uncertain(executor, Task.await(mutation, @timeout))
      assert_receive {:peer, "DELETE", {:error, :closed}}, @timeout

      fresh = %{binding: client(fixture, connection)}
      assert {:ok, result} = run(executor, get, %{input | "name" => "ready"}, fresh)
      assert_read(executor, result)

      assert Enum.map(OperationsFixture.backend_requests(fixture), fn request ->
               {request.method, OperationsFixture.path(request), OperationsFixture.query(request)}
             end) == [{"GET", @held, @query}, {"DELETE", @held, @query}, {"GET", @ready, @query}]
    end
  end

  defp routes(parent) do
    fn request ->
      case OperationsFixture.path(request) do
        @held ->
          %{
            upgrade: fn transport, socket ->
              send(parent, {:held, request.method, request.target})
              send(parent, {:peer, request.method, transport.recv(socket, 0, 10_000)})
            end
          }

        @ready ->
          OperationsFixture.sync(%{"name" => "ready"}, %{"etag" => "fixture-etag"})

        _ ->
          :next
      end
    end
  end

  defp client(fixture, connection),
    do: %Incus{connection: connection, context: fixture.context, server: %Server{}}

  defp run(executor, name, input, caller),
    do: executor.run(name, input, host: OperationsHost, caller: caller, scopes: executor.scopes())

  defp assert_uncertain(Composite, result),
    do: assert({:ok, %{"status" => "uncertain", "operation_id" => nil}} = result)

  defp assert_uncertain(Native, result),
    do: assert({:error, %{"kind" => "uncertain"}} = result)

  defp assert_read(Composite, result), do: assert(%{"item" => %{"name" => "ready"}} = result)

  defp assert_read(Native, result),
    do: assert(%{"metadata" => %{"name" => "ready"}, "etag" => "fixture-etag"} = result)
end
