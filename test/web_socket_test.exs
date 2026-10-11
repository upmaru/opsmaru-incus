defmodule Opsmaru.Incus.WebSocketTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Events, Server, WebSocket}
  alias Opsmaru.TestSupport.{HTTPFixture, WebSocketFixture}
  @driver Path.expand("../../.integration/incus-ws-driver", __DIR__)
  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-ws-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "official and Elixir clients agree on native WebSocket handshake/binary duplex", %{
    root: root
  } do
    fixture = fixture(root, [])
    file = Path.join(root, "input.json")
    payload = <<255, 0, 128, 42>>

    File.write!(
      file,
      Jason.encode!(%{
        socket: WebSocketFixture.path(fixture),
        transfer: "websocket",
        path: "/operations/native/websocket?secret=fixture",
        payload: Base.encode64(payload)
      })
    )

    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    result = Jason.decode!(out)
    assert Base.decode64!(result["initial"]) == <<0, 255, 128>>
    assert Base.decode64!(result["echo"]) == payload

    {:ok, channel} =
      WebSocket.open(client(fixture), "/1.0/operations/native/websocket?secret=fixture")

    assert {:ok, {:binary, <<0, 255, 128>>}} = WebSocket.recv(channel)
    assert :ok = WebSocket.send_frame(channel, {:binary, payload})
    assert {:ok, {:binary, ^payload}} = WebSocket.recv(channel)
    assert :ok = WebSocket.close(channel)
    refute Process.alive?(channel.pid)

    requests =
      WebSocketFixture.requests(fixture) |> Enum.reject(&(URI.parse(&1.target).path == "/1.0"))

    assert length(requests) == 2
    assert Enum.all?(requests, &(URI.parse(&1.target).path == "/1.0/operations/native/websocket"))
  end

  test "events retain native models and overflow fails visibly without affecting other requests",
       %{root: root} do
    event =
      Jason.encode!(%{
        type: "operation",
        timestamp: "2026-10-10T00:00:00Z",
        metadata: %{id: "native", status_code: 200},
        project: "fixture"
      })

    fixture = fixture(root, wire: WebSocketFixture.frame(1, event))
    {:ok, channel} = Events.subscribe(client(fixture), types: ["operation"])
    assert {:ok, model} = Events.next(channel)
    assert model.type == "Event"
    assert model.data["metadata"]["id"] == "native"
    Events.close(channel)
    overflow = fixture(root, wire: :binary.copy(WebSocketFixture.frame(1, event), 3))
    configured = client(overflow)
    configured = %{configured | connection: %{configured.connection | queue_limit: 1}}
    assert {:error, %Error{kind: :overflow}} = Events.subscribe(configured)
    # Initial coalesced overflow fails during open; an independent channel works.
    {:ok, other} = Events.subscribe(client(fixture))
    assert {:ok, _} = Events.next(other)
    Events.close(other)
  end

  test "remote EOF is notified once while queued tail frames remain readable", %{root: root} do
    payload = <<255, 0, 128, 42>>

    fixture =
      fixture(root,
        wire: WebSocketFixture.frame(2, payload) <> WebSocketFixture.frame(8, <<1000::16>>)
      )

    {:ok, channel} = WebSocket.open(client(fixture), "/1.0/events")
    ref = channel.ref
    assert_receive {^ref, :eof}, 1_000
    assert {:ok, {:binary, ^payload}} = WebSocket.recv(channel)
    assert :eof = WebSocket.recv(channel)
    assert :eof = WebSocket.recv(channel)
    refute_receive {^ref, :eof}, 100
    assert Process.alive?(channel.pid)
    assert :ok = WebSocket.close(channel)
  end

  test "fragment buffers and lifetime are bounded and owner death releases the connection", %{
    root: root
  } do
    fixture = fixture(root, wire: "")
    configured = client(fixture)
    configured = %{configured | connection: %{configured.connection | stream_timeout: 40}}
    {:ok, channel} = WebSocket.open(configured, "/1.0/events")
    ref = channel.ref
    assert_receive {^ref, :error, %Error{kind: :deadline}}, 1_000
    refute Process.alive?(channel.pid)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, channel} = WebSocket.open(client(fixture), "/1.0/events")
        send(parent, {:channel, channel})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:channel, channel}, 5_000
    monitor = Process.monitor(channel.pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000
  end

  test "rejected upgrade bodies remain bounded and malformed responses retain HTTP status", %{
    root: root
  } do
    for {status, body, budget, kind} <- [
          {403, %{type: "error", error_code: 777, error: String.duplicate("x", 1024)}, 128,
           :frame_limit},
          {403, %{unexpected: "not an Incus envelope"}, 4096, :websocket_upgrade},
          {200, %{type: "sync", metadata: %{}}, 4096, :websocket_upgrade}
        ] do
      fixture =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(root, "reject-#{System.unique_integer([:positive])}"),
           handler: fn _ -> %{status: status, body: body} end},
          id: make_ref()
        )

      connection =
        Connection.unix!(HTTPFixture.endpoint(fixture).socket,
          owner: :fixture,
          max_response_bytes: budget
        )

      configured = %Incus{
        connection: connection,
        context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
        server: %Server{api_extensions: []}
      }

      assert {:error, %Error{kind: ^kind} = error} = WebSocket.open(configured, "/1.0/events")
      if kind == :websocket_upgrade, do: assert(error.http_status == status)
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  defp fixture(root, opts),
    do:
      start_supervised!(
        {WebSocketFixture,
         [path: Path.join(root, "s-#{System.unique_integer([:positive])}")] ++ opts},
        id: make_ref()
      )

  defp client(fixture),
    do: %Incus{
      connection: Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: []}
    }
end
