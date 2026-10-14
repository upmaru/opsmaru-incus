defmodule Opsmaru.EmbeddingTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.ClientSupervisor
  alias Opsmaru.Incus.Connection
  alias Opsmaru.Incus.Context

  test "library startup/restart is passive under a hostile web environment" do
    System.put_env("PHX_SERVER", "true")
    System.put_env("PORT", "not-a-port")
    on_exit(fn -> Enum.each(["PHX_SERVER", "PORT"], &System.delete_env/1) end)
    ports = MapSet.new(Port.list())
    registered = MapSet.new(Process.registered())

    assert Application.spec(:opsmaru_incus, :mod) == []
    Application.stop(:opsmaru_incus)
    {:ok, _} = Application.ensure_all_started(:opsmaru_incus)

    assert MapSet.subset?(MapSet.new(Port.list()), ports)
    assert MapSet.subset?(MapSet.new(Process.registered()), registered)
  end

  test "explicit host binding gates readiness without invoking platform adapters" do
    {:ok, host} = Agent.start_link(fn -> false end)

    context =
      Context.new!(owner: :macus, identity: :verified, ready?: fn -> Agent.get(host, & &1) end)

    first = Connection.unix!("/private/fixture-one.sock", owner: :macus, project: "one")
    second = Connection.unix!("/private/fixture-two.sock", owner: :other, project: "two")
    assert {:error, :host_not_ready} = Context.authorize(context, first)
    assert {:error, :owner_mismatch} = Context.authorize(context, second)
    Agent.update(host, fn _ -> true end)
    assert :ok = Context.authorize(context, first)
    assert Connection.project(first, "new").project == "new"
    assert first.project == "one"
    assert second.project == "two"
    Agent.stop(host)
  end

  test "optional supervision rejects capacity and never restarts work or host runtime" do
    {:ok, runtime} = Agent.start_link(fn -> :running end)
    supervisor = start_supervised!({ClientSupervisor, max_children: 1})
    parent = self()

    {:ok, task} =
      ClientSupervisor.async(supervisor, fn ->
        send(parent, :started)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :started

    assert {:error, :capacity} =
             ClientSupervisor.async(supervisor, fn -> flunk("queued work") end)

    Task.shutdown(task, :brutal_kill)
    assert Task.Supervisor.children(supervisor) == []
    assert Agent.get(runtime, & &1) == :running
    {:ok, next} = ClientSupervisor.async(supervisor, fn -> :explicit_call end)
    assert Task.await(next) == :explicit_call
    stop_supervised!(Task.Supervisor)
    restarted = start_supervised!({ClientSupervisor, max_children: 1})
    assert Task.Supervisor.children(restarted) == []
    assert Agent.get(runtime, & &1) == :running
    Agent.stop(runtime)
  end

  test "constructors are passive and credentials cannot escape through inspect" do
    assert_raise ArgumentError, fn -> Connection.unix!("relative.sock", owner: :host) end
    assert_raise ArgumentError, fn -> Connection.https!("http://host", owner: :host) end

    tls = [
      cacertfile: "/missing/secret-ca",
      certfile: "/missing/secret-cert",
      keyfile: "/missing/secret-key"
    ]

    connection = Connection.https!("https://backend.invalid", owner: :host, tls: tls)
    refute inspect(connection) =~ "secret"
    refute inspect(connection) =~ "backend.invalid"
    context = Context.new!(owner: :host, identity: "secret-identity", ready?: fn -> true end)
    refute inspect(context) =~ "secret-identity"
    assert :ok = Context.authorize(context, connection)

    assert_raise ArgumentError, fn ->
      Connection.unix!("/fixture", owner: :host, timeout: :infinity)
    end
  end
end
