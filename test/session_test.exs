defmodule Opsmaru.Incus.SessionTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Server, Session, WebSocket}
  alias Opsmaru.TestSupport.{HTTPFixture, WebSocketFixture}

  test "session close stops multiple blocked channels within a shared local budget" do
    root = Path.join(System.tmp_dir!(), "op-session-block-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "s"),
         handler: fn request ->
           %{
             upgrade: fn transport, socket ->
               accept =
                 Base.encode64(
                   :crypto.hash(
                     :sha,
                     request.headers["sec-websocket-key"] <>
                       "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                   )
                 )

               :ok =
                 transport.send(
                   socket,
                   "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
                 )

               receive do
                 :never -> :ok
               after
                 10_000 -> :ok
               end
             end
           }
         end}
      )

    client = %Incus{
      connection:
        Connection.unix!(HTTPFixture.endpoint(fixture).socket,
          owner: :fixture,
          timeout: 5_000,
          stream_timeout: 30_000,
          max_stream_bytes: 67_108_864
        ),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: []}
    }

    channels =
      for name <- ["0", "control"], into: %{} do
        {:ok, channel} = WebSocket.open(client, "/1.0/events")
        {name, channel}
      end

    on_exit(fn ->
      for {_, channel} <- channels,
          Process.alive?(channel.pid),
          do: Process.exit(channel.pid, :kill)
    end)

    session = %Session{operation: %{url: "/1.0/operations/accepted-exec"}, channels: channels}

    writers =
      for {_, channel} <- channels do
        socket = :sys.get_state(channel.pid).conn |> Mint.HTTP.get_socket()
        :ok = :inet.setopts(socket, sndbuf: 1024)

        Task.async(fn ->
          Enum.reduce_while(1..64, nil, fn _, _ ->
            case WebSocket.send_frame(channel, {:binary, :binary.copy(<<7>>, 1_048_576)}) do
              :ok -> {:cont, nil}
              error -> {:halt, error}
            end
          end)
        end)
      end

    for {_, channel} <- channels,
        do: await_session_write(channel.pid, System.monotonic_time(:millisecond) + 1_000)

    monitors = for {_, channel} <- channels, do: Process.monitor(channel.pid)
    before = System.monotonic_time(:millisecond)
    assert :ok = Session.close(session)
    for monitor <- monitors, do: assert_receive({:DOWN, ^monitor, :process, _, _}, 500)
    assert System.monotonic_time(:millisecond) - before < 500
    for writer <- writers, do: assert({:error, %Error{}} = Task.await(writer))
    assert session.operation.url == "/1.0/operations/accepted-exec"
    assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))
  end

  defp await_session_write(pid, deadline) do
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)

    unless Enum.any?(stack, fn {module, function, _, _} ->
             module == :prim_inet and function == :send
           end) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      await_session_write(pid, deadline)
    end
  end

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
