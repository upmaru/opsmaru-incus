defmodule Opsmaru.Incus.OperationHandlerTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus

  alias Opsmaru.Incus.{
    Connection,
    Context,
    Error,
    EventListener,
    Migration,
    Model,
    Operation,
    Server
  }

  alias Opsmaru.TestSupport.WebSocketFixture
  @driver Path.expand("../.integration/operation-handlers-driver", __DIR__)
  @time "2026-01-01T00:00:00Z"

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./operationhandlers"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-handlers-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "handlers receive this operation's decoded events exactly like the pinned client", %{
    root: root
  } do
    {client, _fixture} = fixture(root, operation("op1", 103))

    events = [
      event(operation("other", 103)),
      event(operation("op1", 103, "Running")),
      %{event(operation("op1", 103)) | "metadata" => %{"id" => 7}},
      event(operation("op1", 200, "Success"))
    ]

    native = oracle(%{socket: client.connection.address, events: events, expect: 2})
    assert native["add_error"] == nil
    refute native["target_nil"]
    # Native delivers the running and the final event for this ID only. It runs
    # each handler in its own goroutine (client/incus_events.go), so its
    # delivery order is not guaranteed; compare it as a set.
    assert Enum.sort(Enum.map(native["seen"], &{&1["id"], &1["status_code"]})) == [
             {"op1", 103},
             {"op1", 200}
           ]

    parent = self()
    {:ok, op} = Operation.raw(client, "DELETE", "/1.0/instances/c1")
    {:ok, listener} = EventListener.open(client)
    assert {:ok, target} = Operation.add_handler(op, listener, &send(parent, {:op, &1}))
    refute is_nil(target)

    {:ok, removed} = Operation.add_handler(op, listener, &send(parent, {:removed, &1}))
    assert :ok = Operation.remove_handler(op, listener, removed)
    assert native["remove"] == nil

    assert {:error, %Error{kind: :invalid_event_target}} =
             Operation.remove_handler(op, listener, removed)

    assert native["remove_again"] != nil

    assert {:error, %Error{kind: :invalid_event_target}} =
             Operation.remove_handler(op, listener, nil)

    assert native["remove_nil"] != nil

    for event <- events, do: assert(:ok = EventListener.send_event(listener, event))
    seen = collect_ops(length(native["seen"]))
    # Our listener dispatches handlers serially, so event order is preserved.
    assert Enum.map(seen, &{&1.data["id"], &1.data["status_code"]}) == [
             {"op1", 103},
             {"op1", 200}
           ]

    assert Enum.sort_by(Enum.map(seen, & &1.data), & &1["status_code"]) ==
             Enum.sort_by(native["seen"], & &1["status_code"])

    assert Enum.all?(seen, &match?(%Model{type: "Operation"}, &1))
    refute_receive {:removed, _}, 100
    refute_receive {:op, _}, 100
    :ok = EventListener.disconnect(listener)
  end

  test "an already successful operation returns no target, as natively", %{root: root} do
    {client, _fixture} = fixture(root, operation("op1", 200, "Success"))
    native = oracle(%{socket: client.connection.address, events: [], expect: 0})
    assert native["add_error"] == nil and native["target_nil"]

    {:ok, op} = Operation.raw(client, "DELETE", "/1.0/instances/c1")
    {:ok, listener} = EventListener.open(client)
    assert {:ok, nil} = Operation.add_handler(op, listener, fn _ -> :ok end)
    :ok = EventListener.disconnect(listener)
  end

  test "an already failed operation returns its native error, as natively", %{root: root} do
    {client, _fixture} = fixture(root, %{operation("op1", 400, "Failure") | "err" => "boom"})
    native = oracle(%{socket: client.connection.address, events: [], expect: 0})
    assert native["add_error"] == "boom" and native["target_nil"]

    {:ok, op} = Operation.raw(client, "DELETE", "/1.0/instances/c1")
    {:ok, listener} = EventListener.open(client)

    assert {:error, %Error{kind: :operation_failed} = error} =
             Operation.add_handler(op, listener, fn _ -> :ok end)

    assert Operation.data(%{op | response: error.response})["err"] == "boom"
    :ok = EventListener.disconnect(listener)
  end

  test "listeners bound to another backend or identity are rejected without I/O", %{root: root} do
    {client, fixture} = fixture(root, operation("op1", 103))
    {other, _} = fixture(root, operation("op1", 103))
    {:ok, op} = Operation.raw(client, "DELETE", "/1.0/instances/c1")
    {:ok, foreign} = EventListener.open(other)
    gets = count_gets(fixture)

    assert {:error, %Error{kind: :invalid_operation_binding}} =
             Operation.add_handler(op, foreign, fn _ -> :ok end)

    assert {:error, %Error{kind: :invalid_operation_binding}} =
             Operation.remove_handler(op, foreign, {make_ref(), make_ref()})

    assert count_gets(fixture) == gets

    other_identity = %{
      client
      | context: Context.new!(owner: :fixture, identity: :other, ready?: fn -> true end)
    }

    {:ok, listener} = EventListener.open(other_identity)

    assert {:error, %Error{kind: :invalid_operation_binding}} =
             Operation.add_handler(op, listener, fn _ -> :ok end)

    assert {:error, %Error{kind: :invalid_event_handler}} =
             Operation.add_handler(op, listener, :nope)

    Enum.each([foreign, listener], &EventListener.disconnect/1)
  end

  test "migration handlers forward to the accepted target or return no target", %{root: root} do
    {client, _fixture} = fixture(root, operation("op1", 103))
    {:ok, op} = Operation.raw(client, "DELETE", "/1.0/instances/c1")
    {:ok, listener} = EventListener.open(client)
    parent = self()

    assert {:ok, target} =
             Migration.add_handler(%Migration{target: op}, listener, &send(parent, {:op, &1}))

    refute is_nil(target)
    :ok = EventListener.send_event(listener, event(operation("op1", 103, "Running")))
    assert [%Model{data: %{"id" => "op1"}}] = collect_ops(1)

    assert {:ok, nil} = Migration.add_handler(%Migration{}, listener, fn _ -> :ok end)

    assert {:error, %Error{kind: :invalid_event_handler}} =
             Migration.add_handler(%Migration{}, listener, nil)

    :ok = EventListener.disconnect(listener)
  end

  defp operation(id, code, status \\ "Running") do
    %{
      "id" => id,
      "class" => "task",
      "description" => "Deleting instance",
      "created_at" => @time,
      "updated_at" => @time,
      "status" => status,
      "status_code" => code,
      "resources" => nil,
      "metadata" => nil,
      "may_cancel" => false,
      "err" => "",
      "location" => "none"
    }
  end

  defp event(metadata),
    do: %{
      "type" => "operation",
      "timestamp" => @time,
      "metadata" => metadata,
      "location" => "none",
      "project" => "default"
    }

  defp collect_ops(count) do
    for _ <- 1..count//1 do
      assert_receive {:op, op}, 2_000
      op
    end
  end

  defp count_gets(fixture),
    do:
      Enum.count(
        WebSocketFixture.requests(fixture),
        &(&1.method == "GET" and &1.target =~ "/operations/")
      )

  defp fixture(root, current) do
    handler = fn
      %{method: "DELETE"} ->
        %{
          status: 202,
          body: %{
            type: "async",
            operation: "/1.0/operations/op1",
            metadata: operation("op1", 103)
          }
        }

      %{method: "GET", target: "/1.0/operations/op1" <> _} ->
        %{status: 200, body: %{type: "sync", metadata: current}}

      _ ->
        %{status: 404, body: %{type: "error", error_code: 404, error: "not found"}}
    end

    fixture =
      start_supervised!(
        {WebSocketFixture,
         path: Path.join(root, "#{System.unique_integer([:positive])}.sock"),
         wire: <<>>,
         http_handler: handler},
        id: make_ref()
      )

    client = %Incus{
      connection: Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{}
    }

    {client, fixture}
  end

  defp oracle(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)

      {^port, {:exit_status, status}} ->
        flunk("native operation handler oracle failed #{status}: #{data}")
    after
      15_000 ->
        Port.close(port)
        flunk("native operation handler oracle deadline")
    end
  end
end
