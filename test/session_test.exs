defmodule Opsmaru.Incus.SessionTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Context
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Connection
  alias Opsmaru.Incus.Server
  alias Opsmaru.Incus.Session
  alias Opsmaru.TestSupport.WebSocketFixture

  test "exec/console negotiate native input/output/control and retain authoritative exit status" do
    root = Path.join(System.tmp_dir!(), "op-session-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    fixture =
      start_supervised!(
        {WebSocketFixture,
         path: Path.join(root, "s"),
         http_handler: fn request ->
           if request.method == "POST" do
             %{
               status: 202,
               body: %{
                 type: "async",
                 operation: "/1.0/operations/native-id",
                 metadata: %{
                   id: "native-id",
                   status_code: 103,
                   metadata: %{
                     fds: %{
                       "0" => "input",
                       "1" => "output",
                       "2" => "error",
                       "control" => "control"
                     }
                   }
                 }
               }
             }
           else
             %{
               status: 200,
               body: %{
                 type: "sync",
                 metadata: %{id: "native-id", status_code: 200, metadata: %{return: 7}}
               }
             }
           end
         end}
      )

    client = %Incus{
      connection: Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: ["console"]}
    }

    for action <- [:exec, :console] do
      result =
        if action == :exec,
          do:
            Session.exec(client, "fixture", %{"command" => ["true"], "wait-for-websocket" => true}),
          else: Session.console(client, "fixture", %{})

      assert {:ok, session} = result
      assert session.operation.url == "/1.0/operations/native-id"
      assert {:ok, {:binary, <<0, 255, 128>>}} = Session.output(session)
      assert {:ok, {:binary, <<0, 255, 128>>}} = Session.output(session, "2")
      assert :ok = Session.input(session, <<255, 0, 128, 42>>)
      assert :ok = Session.resize(session, 80, 24)
      assert :ok = Session.signal(session, 15)
      assert :ok = Session.close_input(session)
      assert {:ok, 7} = Session.exit_status(session)
      assert :ok = Session.close(session)
      assert Enum.all?(session.channels, fn {_, channel} -> not Process.alive?(channel.pid) end)
    end

    requests = WebSocketFixture.requests(fixture)
    assert Enum.count(requests, &(&1.method == "POST")) == 2
    assert Enum.count(requests, &Map.has_key?(&1.headers, "sec-websocket-key")) == 8
  end
end
