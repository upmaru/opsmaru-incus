defmodule Opsmaru.Incus.GatewayAdmissionTest do
  # Task 1.2: host-started bounded admission, callback deadlines, caller loss,
  # restart cleanup and redacted diagnostics.
  use Opsmaru.TestSupport.GatewayCase, async: true

  test "admission is explicit configuration and validates its bound" do
    assert_raise ArgumentError, fn -> Admission.start_link(max_exchanges: 0) end
    assert_raise ArgumentError, fn -> Admission.start_link(max_exchanges: 100_000) end
    assert_raise KeyError, fn -> Admission.start_link([]) end
  end

  test "slots are tied to their holder and released when it exits" do
    admission = start_supervised!({Admission, max_exchanges: 2, id: :unit})
    holder = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, slot} = Admission.acquire(admission, holder)
    assert {:ok, _} = Admission.acquire(admission, self())
    assert {:error, :capacity} = Admission.acquire(admission, self())
    Process.exit(holder, :kill)
    wait_until(fn -> Admission.count(admission) == 1 end)
    # Releasing an already released slot is harmless.
    Admission.release(slot)
    assert Admission.count(admission) == 1
  end

  test "an unavailable admission is reported, not raised" do
    assert {:error, :unavailable} = Admission.acquire(:no_such_admission)
  end

  test "status and crash reports show only a count" do
    admission = start_supervised!({Admission, max_exchanges: 2, id: :status})
    holder = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, _} = Admission.acquire(admission, holder)
    rendered = inspect(:sys.get_status(admission))
    refute rendered =~ inspect(holder)
    assert rendered =~ "slots: 1"
    Process.exit(holder, :kill)
  end

  test "at capacity a request is rejected with no backend and nothing queued", context do
    admission = start_supervised!({Admission, max_exchanges: 1, id: :small})
    parent = self()

    {backend, connection} =
      backend(context, fn conn ->
        {conn, _, _} = StreamBackend.read_body(conn)
        send(parent, {:holding, self()})

        receive do
          :release -> StreamBackend.write(conn, StreamBackend.json(200, %{}))
        end
      end)

    mount(context, connection)
    GatewayServer.put_gateway(%{GatewayServer.gateway() | admission: admission})
    first = Task.async(fn -> get(context, "/1.0/instances") end)
    assert_receive {:holding, worker}, 2_000

    second = get(context, "/1.0/instances")
    assert second.status == 503
    assert native(second.body)["error"] == "Gateway is at capacity"
    assert StreamBackend.accepted(backend) == 1
    # Rejected before the host was asked.
    assert_received {:host_authorize, _}
    refute_received {:host_authorize, _}

    send(worker, :release)
    assert Task.await(first).status == 200
    wait_until(fn -> Admission.count(admission) == 0 end)
    third = Task.async(fn -> get(context, "/1.0/instances") end)
    assert_receive {:holding, worker}, 2_000
    send(worker, :release)
    assert Task.await(third).status == 200
  end

  test "denied or failed callbacks hold no slot", context do
    {_, connection} = backend(context, reply(200, %{}))
    mount(context, connection, host_config: %{ready: false})
    for _ <- 1..10, do: assert(get(context, "/1.0/instances").status == 503)
    assert Admission.count(context.admission) == 0
  end

  test "a restarted admission serves new exchanges and forgets old holders", context do
    {_, connection} =
      backend(context, fn conn ->
        {conn, _, _} = StreamBackend.read_body(conn)
        StreamBackend.await_close(conn, 10_000)
      end)

    # Hosts refer to admission by name, so a supervised restart is picked up.
    start_supervised!({Admission, name: GatewayAdmissionRestart, max_exchanges: 4, id: :named})
    mount(context, connection)
    GatewayServer.put_gateway(%{GatewayServer.gateway() | admission: GatewayAdmissionRestart})
    task = Task.async(fn -> get(context, "/1.0/events") end)
    assert_receive {:backend_request, _}, 2_000
    old = Process.whereis(GatewayAdmissionRestart)
    assert Admission.count(old) == 1

    Process.exit(old, :kill)
    assert Task.await(task, 5_000).status == 503
    assert_receive {:backend_closed, _}, 2_000

    wait_until(fn ->
      pid = Process.whereis(GatewayAdmissionRestart)
      is_pid(pid) and pid != old
    end)

    assert Admission.count(GatewayAdmissionRestart) == 0
    {_, connection} = backend(context, reply(200, %{}))
    mount(context, connection)
    GatewayServer.put_gateway(%{GatewayServer.gateway() | admission: GatewayAdmissionRestart})
    assert get(context, "/1.0/instances").status == 200
  end

  test "two hosts' admissions are independent", context do
    other = start_supervised!({Admission, max_exchanges: 1, id: :other})
    {:ok, _} = Admission.acquire(other, self())
    {_, connection} = backend(context, reply(200, %{}))
    mount(context, connection)
    assert get(context, "/1.0/instances").status == 200
    assert Admission.count(other) == 1
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end
