defmodule Opsmaru.Incus.SFTPSessionTest do
  @moduledoc """
  Shared concurrent SFTP sessions against a scripted SFTP server: pipelined requests
  matched by id from many processes, opener-bound lifetime, per-request deadlines,
  frame failures and the in-flight bound.
  """
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Server, SFTP}
  alias Opsmaru.TestSupport.HTTPFixture

  setup do
    root = Path.join(System.tmp_dir!(), "op-sftp-session-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "concurrent callers share a session and get their own replies when the server answers out of order",
       %{root: root} do
    # Hold eight stat requests, then answer them in reverse order.
    script = fn
      {:request, <<17, id::32, path::binary>>}, held when length(held) < 7 ->
        {[], [{id, path} | held]}

      {:request, <<17, id::32, path::binary>>}, held ->
        replies = for {id, <<_::32, name::binary>>} <- [{id, path} | held], do: attrs(id, name)
        {replies, []}
    end

    fixture = backend(root, script, [])
    {:ok, session} = open(fixture)

    results =
      for name <- Enum.map(1..8, &"file-#{&1}") do
        Task.async(fn -> {name, SFTP.stat(session, name)} end)
      end
      |> Task.await_many(5_000)

    # Each attribute reply carries the requested name's size, so a mixed-up match shows.
    for {name, {:ok, stat}} <- results,
        do: assert(stat.size == byte_size(name) and stat.name == name)

    assert length(results) == 8
    assert_received_requests(8)
    SFTP.close(session)
  end

  test "the opener's exit closes the session; another caller's exit does not", %{root: root} do
    script = fn {:request, <<type, id::32, _::binary>>}, state ->
      if type == 17, do: {[attrs(id, "x")], state}, else: {[], state}
    end

    fixture = backend(root, script)
    parent = self()

    opener =
      spawn(fn ->
        {:ok, session} = open(fixture)
        send(parent, {:session, session})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:session, session}, 2_000
    caller = spawn(fn -> SFTP.stat(session, "x") end)
    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert {:ok, _} = SFTP.stat(session, "x")
    assert Process.alive?(session.pid)

    # A stalled read from another process fails when the opener goes away.
    stalled = Task.async(fn -> SFTP.read_dir(session, "stalled") end)
    Process.sleep(100)
    send(opener, :exit)
    assert {:error, %Error{kind: :channel_closed}} = Task.await(stalled, 2_000)
    eventually_dead(session.pid)
    assert {:error, %Error{kind: kind}} = SFTP.stat(session, "x")
    assert kind in [:channel_closed, :canceled]
  end

  test "a request deadline fails only that request; a late reply is discarded", %{root: root} do
    script = fn
      {:request, <<17, id::32, _::binary>>}, nil ->
        # Hold the first stat, answer everything after it, then release it late.
        {[], id}

      {:request, <<17, id::32, _::binary>>}, held ->
        {[attrs(id, "x"), {:after, 50, attrs(held, "late")}], :done}

      {:request, <<type, id::32, _::binary>>}, state when type in [13, 15] ->
        {[], {state, id}}
    end

    fixture = backend(root, script)
    {:ok, session} = open(fixture, timeout: 300)
    assert {:error, %Error{kind: :deadline} = error} = SFTP.stat(session, "first")
    assert error.response.request_id == 1
    # As natively, the name is the base of the requested path.
    assert {:ok, %{name: "second", size: 1}} = SFTP.stat(session, "second")
    Process.sleep(150)
    assert Process.alive?(session.pid)

    # A timed-out mutation is uncertain, and a compound call stops instead of
    # sending its next step (pkg/sftp Remove would try RMDIR).
    assert {:error, %Error{kind: :uncertain, response: %{request_id: 3}}} =
             SFTP.remove(session, "file")

    requests = requests()
    assert Enum.map(requests, &:binary.first/1) == [1, 17, 17, 13]
    assert Process.alive?(session.pid)
    SFTP.close(session)
  end

  test "an unmatched reply id ends the session and fails every pending request", %{root: root} do
    script = fn
      {:request, <<type, id::32, _::binary>>}, nil when type in [17, 14] ->
        {[], id}

      {:request, <<type, id::32, _::binary>>}, _ when type in [17, 14] ->
        {[attrs(id + 100, "x")], :sent}
    end

    fixture = backend(root, script)
    {:ok, session} = open(fixture)
    read = Task.async(fn -> SFTP.stat(session, "a") end)
    Process.sleep(50)
    mutation = Task.async(fn -> SFTP.mkdir(session, "b") end)
    assert {:error, %Error{kind: :sftp_protocol}} = Task.await(read, 2_000)
    assert {:error, %Error{kind: :uncertain}} = Task.await(mutation, 2_000)
    eventually_dead(session.pid)
  end

  test "a malformed matched reply fails alone and the session continues", %{root: root} do
    script = fn
      {:request, <<17, id::32, "\0\0\0\x05short">>}, state ->
        # ATTRS announcing a size it does not carry.
        {[<<105, id::32, 1::32, 0::16>>], state}

      {:request, <<17, id::32, _::binary>>}, state ->
        {[attrs(id, "ok")], state}
    end

    fixture = backend(root, script)
    {:ok, session} = open(fixture)
    assert {:error, %Error{kind: :sftp_protocol}} = SFTP.stat(session, "short")
    assert {:ok, %{name: "ok", size: 2}} = SFTP.stat(session, "ok")
    SFTP.close(session)
  end

  test "in-flight requests are bounded by the connection queue limit without sending more",
       %{root: root} do
    script = fn {:request, _}, state -> {[], state} end
    fixture = backend(root, script)
    {:ok, session} = open(fixture, queue_limit: 2, timeout: 1_000)
    tasks = for name <- ["a", "b"], do: Task.async(fn -> SFTP.stat(session, name) end)
    Process.sleep(100)
    assert {:error, %Error{kind: :sftp_limit}} = SFTP.stat(session, "c")
    assert Enum.map(requests(), &:binary.first/1) == [1, 17, 17]
    Task.await_many(tasks, 2_000)
    SFTP.close(session)
  end

  test "a request that waited past its caller's deadline is never sent", %{root: root} do
    script = fn {:request, <<type, id::32, _::binary>>}, state ->
      if type == 17, do: {[attrs(id, "x")], state}, else: {[], state}
    end

    fixture = backend(root, script)
    {:ok, session} = open(fixture, timeout: 200)
    :ok = :sys.suspend(session.pid)
    mutation = Task.async(fn -> SFTP.mkdir(session, "late") end)
    Process.sleep(300)
    :ok = :sys.resume(session.pid)

    # Nothing was dispatched, so the failure is a plain deadline, not uncertain.
    assert {:error, %Error{kind: :deadline} = error} = Task.await(mutation, 2_000)
    refute error.response[:request_id]
    assert {:ok, _} = SFTP.stat(session, "x")
    assert Enum.map(requests(), &:binary.first/1) == [1, 17]
    SFTP.close(session)
  end

  test "a session ended by an invalid frame stops its reader", %{root: root} do
    script = fn {:request, _}, state -> {[{:raw, <<0::32>>}], state} end
    fixture = backend(root, script)
    {:ok, session} = open(fixture)
    reader = Process.monitor(:sys.get_state(session.pid).reader)
    assert {:error, %Error{kind: :sftp_limit}} = SFTP.stat(session, "x")
    assert_receive {:DOWN, ^reader, :process, _, _}, 2_000
    eventually_dead(session.pid)
  end

  defp attrs(id, name),
    do: <<105, id::32, 1::32, byte_size(name)::64>>

  defp assert_received_requests(count) do
    assert length(requests()) == count + 1
  end

  defp requests(acc \\ []) do
    receive do
      {:sftp_request, body} -> requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp eventually_dead(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
  end

  defp backend(root, script, initial \\ nil) do
    parent = self()

    handler = fn request ->
      if request.target == "/1.0" do
        %{status: 200, body: %{type: "sync", metadata: %{api_version: "1.0", api_extensions: []}}}
      else
        %{upgrade: fn transport, socket -> serve(transport, socket, script, parent, initial) end}
      end
    end

    start_supervised!(
      {HTTPFixture,
       [
         transport: :gen_tcp,
         handler: handler,
         path: Path.join(root, "s#{System.unique_integer([:positive])}")
       ]},
      id: make_ref()
    )
  end

  defp serve(transport, socket, script, parent, initial) do
    :ok =
      transport.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: sftp\r\n\r\n"
      )

    {:ok, init} = receive_frame(transport, socket)
    send(parent, {:sftp_request, init})
    :ok = transport.send(socket, frame(<<2, 3::32>>))
    loop(transport, socket, script, parent, initial)
  end

  defp loop(transport, socket, script, parent, state) do
    case receive_frame(transport, socket) do
      {:ok, body} ->
        send(parent, {:sftp_request, body})
        {replies, state} = script.({:request, body}, state)

        for reply <- replies do
          case reply do
            {:after, delay, bytes} ->
              Process.sleep(delay)
              transport.send(socket, frame(bytes))

            {:raw, bytes} ->
              transport.send(socket, bytes)

            bytes ->
              transport.send(socket, frame(bytes))
          end
        end

        loop(transport, socket, script, parent, state)

      :closed ->
        :ok
    end
  end

  defp receive_frame(transport, socket) do
    with {:ok, <<length::32>>} <- transport.recv(socket, 4, 10_000),
         {:ok, body} <- transport.recv(socket, length, 5_000) do
      {:ok, body}
    else
      _ -> :closed
    end
  end

  defp frame(body), do: <<byte_size(body)::32, body::binary>>

  defp open(fixture, opts \\ []) do
    connection =
      Connection.unix!(
        HTTPFixture.endpoint(fixture).socket,
        [owner: :fixture, timeout: 2_000, stream_timeout: 10_000, max_chunk_bytes: 132_096] ++
          opts
      )

    Incus.file_sftp(
      %Incus{
        connection: connection,
        context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
        server: %Server{api_extensions: []}
      },
      "fixture"
    )
  end
end
