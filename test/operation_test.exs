defmodule Opsmaru.Incus.OperationTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Operation}
  alias Opsmaru.TestSupport.HTTPFixture

  setup do
    root = Path.join(System.tmp_dir!(), "op-op-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "accepted handles retain backend/identity binding and waiting observes authoritative completion",
       %{root: root} do
    {:ok, state} = Agent.start_link(fn -> 103 end)
    fixture = backend(root, state)
    client = client(fixture)
    {:ok, accepted} = Incus.call(client, "DeleteInstance", %{"name" => "fixture"})
    assert {:ok, operation} = Operation.from_response(client, accepted)
    assert operation.url == "/1.0/operations/native-id"
    refute Operation.completed?(operation)

    assert {:error, %Error{kind: :invalid_operation_binding}} =
             Operation.from_response(
               %{client | context: %{client.context | identity: :other}},
               accepted
             )

    assert {:error, %Error{kind: :deadline, operation: "/1.0/operations/native-id"}} =
             Operation.wait(operation, timeout: 30, poll_interval: 5)

    refute Enum.any?(
             HTTPFixture.requests(fixture),
             &(&1.method == "DELETE" and String.contains?(&1.target, "operations"))
           )

    Agent.update(state, fn _ -> 200 end)
    assert {:ok, completed} = Operation.wait(operation, timeout: 100)
    assert Operation.completed?(completed)
    assert Operation.successful?(completed)
    Agent.stop(state)
  end

  test "supported cancellation is one native request; completion race preserves native data", %{
    root: root
  } do
    {:ok, state} = Agent.start_link(fn -> 103 end)
    fixture = backend(root, state)
    client = client(fixture)
    {:ok, accepted} = Incus.call(client, "DeleteInstance", %{"name" => "fixture"})
    {:ok, operation} = Operation.from_response(client, accepted)
    assert {:ok, requested} = Operation.cancel(operation)
    refute Operation.completed?(requested)

    assert Enum.count(
             HTTPFixture.requests(fixture),
             &(&1.method == "DELETE" and String.contains?(&1.target, "operations"))
           ) == 1

    Agent.update(state, fn _ -> 200 end)
    assert {:ok, completed} = Operation.cancel(operation)
    assert Operation.completed?(completed)

    assert Enum.count(
             HTTPFixture.requests(fixture),
             &(&1.method == "DELETE" and String.contains?(&1.target, "operations"))
           ) == 1

    Agent.stop(state)
  end

  defp client(fixture),
    do: %Incus{
      connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Opsmaru.Incus.Server{api_extensions: []}
    }

  defp backend(root, state),
    do:
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "sock"),
         handler: fn request ->
           cond do
             String.contains?(request.target, "/instances/") ->
               %{
                 status: 202,
                 body: %{
                   type: "async",
                   operation: "/1.0/operations/native-id",
                   metadata: %{id: "native-id", status_code: 103}
                 }
               }

             request.method == "DELETE" ->
               %{status: 200, body: %{type: "sync", metadata: nil}}

             true ->
               %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{
                     id: "native-id",
                     status_code: Agent.get(state, & &1),
                     may_cancel: true,
                     metadata: %{return: 0}
                   }
                 }
               }
           end
         end}
      )
end
