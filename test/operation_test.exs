defmodule Opsmaru.Incus.OperationTest do
  # The timeout race briefly holds the node-local notifier at its reply boundary.
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Operation, RequestContext}
  alias Opsmaru.Incus.RequestContext.Notifier
  alias Opsmaru.TestSupport.HTTPFixture

  @timeout 5_000
  @operation_url "/1.0/operations/native-id"

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

  test "a scoped wait keeps the GET refresh cadence and releases its mailbox on success", %{
    root: root
  } do
    parent = self()
    {:ok, state} = Agent.start_link(fn -> 103 end)

    fixture =
      backend(root, state, fn status ->
        send(parent, {:refresh, status, System.monotonic_time(:millisecond)})
        snapshot(status)
      end)

    operation = %Operation{client: client(fixture), url: @operation_url}
    context = RequestContext.new!(timeout: @timeout)
    interval = 200
    {waiter, tag} = wait_in_caller(operation, context, timeout: @timeout, poll_interval: interval)

    assert_receive {:refresh, 103, first}, @timeout
    Agent.update(state, fn _ -> 200 end)
    assert_receive {:refresh, 200, second}, @timeout
    assert second - first >= interval

    assert_receive {^tag, {:ok, completed}}, @timeout
    assert Operation.successful?(completed)
    assert completed.url == @operation_url
    assert completed.client == Incus.with_context(operation.client, context)
    assert_clean_mailbox(waiter, tag)
    assert RequestContext.status(context) == :active
    assert_gets(fixture, 2)
  end

  test "cancellation wakes a sleeping caller and retains its last refresh", %{root: root} do
    {:ok, state} = Agent.start_link(fn -> 103 end)
    fixture = backend(root, state)
    operation = %Operation{client: client(fixture), url: @operation_url}
    context = RequestContext.new!(timeout: @timeout)
    {waiter, tag} = wait_in_caller(operation, context, timeout: @timeout, poll_interval: 60_000)

    awaiting_refresh(waiter.pid)
    pid = waiter.pid
    :erlang.trace(pid, true, [:running])
    refute_receive {:trace, ^pid, :in, _}, 100
    :erlang.trace(pid, false, [:running])

    assert :ok = RequestContext.cancel(context)

    assert_receive {^tag, {:error, %Error{kind: :canceled, operation: @operation_url} = error}},
                   500

    assert error.response.metadata.data["status_code"] == 103
    assert_clean_mailbox(waiter, tag)
    assert_gets(fixture, 1)
  end

  test "cancelling an in-flight refresh leaves the last snapshot and the caller's mailbox intact",
       %{root: root} do
    parent = self()
    {:ok, state} = Agent.start_link(fn -> 103 end)

    fixture =
      backend(root, state, fn
        103 ->
          Agent.update(state, fn _ -> :stall end)
          snapshot(103)

        :stall ->
          %{
            upgrade: fn transport, socket ->
              send(parent, :refresh_pending)
              send(parent, {:peer, transport.recv(socket, 0, @timeout)})
            end
          }
      end)

    operation = %Operation{client: client(fixture), url: @operation_url}
    context = RequestContext.new!(timeout: @timeout)
    {waiter, tag} = wait_in_caller(operation, context, timeout: @timeout, poll_interval: 5)

    assert_receive :refresh_pending, @timeout
    assert :ok = RequestContext.cancel(context)

    assert_receive {^tag, {:error, %Error{kind: :canceled, operation: @operation_url} = error}},
                   @timeout

    assert error.response.metadata.data["status_code"] == 103
    assert_receive {:peer, {:error, :closed}}, @timeout
    assert_clean_mailbox(waiter, tag)
    assert_gets(fixture, 2)
  end

  test "the context deadline caps the refresh interval and releases the caller's mailbox", %{
    root: root
  } do
    {:ok, state} = Agent.start_link(fn -> 103 end)
    fixture = backend(root, state)
    operation = %Operation{client: client(fixture), url: @operation_url}
    context = RequestContext.new!(timeout: 500)
    {waiter, tag} = wait_in_caller(operation, context, timeout: @timeout, poll_interval: 60_000)

    assert_receive {^tag, {:error, %Error{kind: :deadline, operation: @operation_url} = error}},
                   @timeout

    assert error.response.metadata.data["status_code"] == 103
    assert System.monotonic_time(:millisecond) >= context.deadline
    assert RequestContext.status(context) == :deadline
    assert_clean_mailbox(waiter, tag)
    assert_gets(fixture, 1)
  end

  test "a notice delivered after the wait deadline cannot reach the returned caller", %{
    root: root
  } do
    {:ok, state} = Agent.start_link(fn -> 103 end)
    fixture = backend(root, state)
    operation = %Operation{client: client(fixture), url: @operation_url}
    context = RequestContext.new!(timeout: @timeout)
    {waiter, tag} = wait_in_caller(operation, context, timeout: 1_000, poll_interval: 60_000)

    awaiting_refresh(waiter.pid)
    notifier = Process.whereis(Notifier)
    monitor = Process.monitor(notifier)
    hold_delivery(notifier, tag)
    assert :ok = RequestContext.cancel(context)
    assert_receive {^tag, :delivery_held}, @timeout

    assert_receive {^tag, {:error, %Error{kind: :deadline, operation: @operation_url} = error}},
                   @timeout

    assert error.response.metadata.data["status_code"] == 103

    send(notifier, {tag, :deliver})
    assert_receive {:DOWN, ^monitor, :process, ^notifier, :normal}, @timeout
    assert_clean_mailbox(waiter, tag)
    assert_gets(fixture, 1)
  end

  defp wait_in_caller(operation, context, opts) do
    parent = self()
    tag = make_ref()

    caller =
      Task.async(fn ->
        Process.monitor(parent)
        send(self(), {:request_context_terminal, tag})
        send(parent, {tag, Operation.wait_with_context(operation, context, opts)})

        receive do
          {^tag, :inspect} -> Process.info(self(), [:messages, :monitors])
        end
      end)

    {caller, tag}
  end

  defp assert_clean_mailbox(waiter, tag) do
    parent = self()
    send(waiter.pid, {tag, :inspect})

    assert [
             messages: [{:request_context_terminal, ^tag}],
             monitors: [{:process, ^parent}]
           ] = Task.await(waiter, @timeout)
  end

  defp awaiting_refresh(pid),
    do: awaiting_refresh(pid, System.monotonic_time(:millisecond) + @timeout)

  defp awaiting_refresh(pid, deadline) do
    case Process.info(pid, [:status, :current_function]) do
      [status: :waiting, current_function: {Operation, :wait_for_context, 2}] ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(1)
        awaiting_refresh(pid, deadline)
    end
  end

  defp hold_delivery(notifier, tag) do
    parent = self()
    on_exit(fn -> send(notifier, {tag, :deliver}) end)

    :ok =
      :sys.install(
        notifier,
        {fn
           _, {:out, :ok, {^parent, _}, _}, _ ->
             send(parent, {tag, :delivery_held})
             receive do: ({^tag, :deliver} -> :done)
             :done

           state, _, _ ->
             state
         end, nil}
      )
  end

  defp assert_gets(fixture, count) do
    assert Enum.map(HTTPFixture.requests(fixture), &{&1.method, &1.target}) ==
             List.duplicate({"GET", @operation_url}, count)
  end

  defp client(fixture),
    do: %Incus{
      connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Opsmaru.Incus.Server{api_extensions: []}
    }

  defp backend(root, state, poll \\ &snapshot/1),
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
               poll.(Agent.get(state, & &1))
           end
         end}
      )

  defp snapshot(status) do
    %{
      status: 200,
      body: %{
        type: "sync",
        metadata: %{
          id: "native-id",
          status_code: status,
          may_cancel: true,
          metadata: %{return: 0}
        }
      }
    }
  end
end
