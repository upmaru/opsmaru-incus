defmodule Opsmaru.Incus.MigrationTargetTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Migration, Operation, Server}
  alias Opsmaru.TestSupport.HTTPFixture

  setup do
    root = Path.join(System.tmp_dir!(), "op-m-target-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "target lookup/wait preserves source ownership and distinguishes deadline from completion",
       %{root: root} do
    {migration, fixture, state} = migration(root)
    assert {:ok, accepted} = Migration.target(migration)
    refute Operation.completed?(accepted)
    assert Enum.count(HTTPFixture.requests(fixture)) == 2

    assert {:error,
            %Error{
              kind: :deadline,
              operation: "/1.0/operations/target",
              response: %{accepted: preserved}
            }} = Migration.wait_target(migration, timeout: 30, poll_interval: 5)

    assert preserved.source == migration.source
    assert preserved.target == migration.target
    refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
    Agent.update(state, fn _ -> 200 end)
    assert {:ok, complete} = Migration.wait_target(migration, timeout: 500)
    assert Operation.completed?(complete.target)
    assert complete.source == migration.source
    refute Operation.completed?(complete.source)

    assert {:error, %Error{kind: :invalid_deadline}} =
             Migration.wait_target(migration, timeout: 50, replay: true)
  end

  test "explicit target cancellation handles completion race and uncertain DELETE once", %{
    root: root
  } do
    {migration, fixture, state} = migration(root, :lost_delete)

    assert {:error, %Error{kind: :uncertain, response: %{accepted: preserved}}} =
             Migration.cancel_target(migration)

    assert preserved.source == migration.source
    assert preserved.target.url == migration.target.url
    assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "DELETE")) == 1
    Agent.update(state, fn _ -> 200 end)
    assert {:ok, completed} = Migration.cancel_target(migration)
    assert Operation.completed?(completed.target)
    assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "DELETE")) == 1
    assert completed.source == migration.source
  end

  test "unaccepted target fails without I/O while retaining accepted source", %{root: root} do
    {migration, fixture, _} = migration(root)
    migration = %{migration | target: nil}
    count = length(HTTPFixture.requests(fixture))

    assert {:error, %Error{kind: :target_unavailable, response: %{accepted: preserved}}} =
             Migration.target(migration)

    assert preserved.source == migration.source
    assert {:error, %Error{kind: :target_unavailable}} = Migration.wait_target(migration)
    assert {:error, %Error{kind: :target_unavailable}} = Migration.cancel_target(migration)
    assert length(HTTPFixture.requests(fixture)) == count
  end

  defp migration(root, outcome \\ :normal) do
    state = start_supervised!({Agent, fn -> 103 end})

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "s"),
         handler: fn request ->
           id = URI.decode_query(URI.parse(request.target).query)["project"]

           cond do
             request.method == "POST" ->
               %{
                 status: 202,
                 body: %{
                   type: "async",
                   operation: "/1.0/operations/" <> id,
                   metadata: %{id: id, status_code: 103}
                 }
               }

             request.method == "DELETE" and outcome == :lost_delete ->
               %{raw: ""}

             request.method == "GET" ->
               %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{id: id, status_code: Agent.get(state, & &1), may_cancel: true}
                 }
               }

             true ->
               %{status: 200, body: %{type: "sync", metadata: %{}}}
           end
         end}
      )

    operations =
      for project <- ["source", "target"] do
        client = %Incus{
          connection:
            Connection.unix!(HTTPFixture.endpoint(fixture).socket,
              owner: project,
              project: project
            ),
          context: Context.new!(owner: project, identity: project, ready?: fn -> true end),
          server: %Server{}
        }

        assert {:ok, operation} = Operation.raw(client, "POST", "/1.0/instances", body: %{})
        operation
      end

    [source, target] = operations
    {%Migration{source: source, target: target, mode: :relay}, fixture, state}
  end
end
