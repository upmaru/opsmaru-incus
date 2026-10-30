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

  describe "files" do
    test "cursor calls take turns; positional calls overlap; a waiting cursor call holds back later ones",
         %{root: root} do
      fixture = backend(root, &files/2, files_state())
      {:ok, session} = open(fixture)
      {:ok, file} = SFTP.open(session, "f")
      hold(session)

      # A cursor read holds the lock; a positional read waits without sending.
      cursor = Task.async(fn -> SFTP.File.read(file, 4) end)
      assert_request(5)
      positional = Task.async(fn -> SFTP.File.read_at(file, 0, 4) end)
      refute_request()
      release(session)
      assert {:ok, <<0, 0, 0, 0>>} = Task.await(cursor)
      assert {:ok, _} = Task.await(positional)
      assert_request(5)

      # Positional reads overlap: both are sent before either is answered.
      hold(session)
      both = for _ <- 1..2, do: Task.async(fn -> SFTP.File.read_at(file, 8, 4) end)
      assert_request(5)
      assert_request(5)

      # A cursor call waits for them, and a later positional read waits behind it.
      seek = Task.async(fn -> SFTP.File.seek(file, 2, :current) end)
      Process.sleep(50)
      later = Task.async(fn -> SFTP.File.read_at(file, 16, 4) end)
      refute_request()
      release(session)
      Enum.each(both, &assert({:ok, _} = Task.await(&1)))
      assert {:ok, 6} = Task.await(seek)
      assert {:ok, _} = Task.await(later)
      assert_request(5)
      SFTP.close(session)
    end

    test "a holder's exit releases the lock; closing fails queued calls without I/O",
         %{root: root} do
      fixture = backend(root, &files/2, files_state())
      {:ok, session} = open(fixture)
      {:ok, file} = SFTP.open(session, "f")
      hold(session)

      holder = spawn(fn -> SFTP.File.read(file, 4) end)
      assert_request(5)
      Process.exit(holder, :kill)
      assert {:ok, 0} = SFTP.File.seek(file, 0, :current)

      stalled = Task.async(fn -> SFTP.File.read(file, 4) end)
      assert_request(5)
      close = Task.async(fn -> SFTP.File.close(file) end)
      Process.sleep(50)
      queued = Task.async(fn -> SFTP.File.read_at(file, 0, 1) end)
      release(session)
      assert {:ok, _} = Task.await(stalled)
      assert :ok = Task.await(close)
      assert {:error, %Error{kind: :file_closed}} = Task.await(queued)
      assert_request(4)
      refute_request()
      assert {:error, %Error{kind: :file_closed}} = SFTP.File.write(file, "x")
      SFTP.close(session)
    end

    test "large reads are pipelined in offset order within Go's window and the connection bound",
         %{root: root} do
      fixture = backend(root, &files/2, files_state())
      {:ok, session} = open(fixture, queue_limit: 200)
      {:ok, file} = SFTP.open(session, "f")
      hold(session)
      count = 70 * 131_072
      read = Task.async(fn -> SFTP.File.read_at(file, 0, count) end)

      # 64 workers plus Go's one read dispatched ahead.
      offsets = for _ <- 1..65, do: read_offset(assert_request(5))
      assert offsets == Enum.map(0..64, &(&1 * 131_072))
      refute_request()
      release(session)
      assert {:ok, data} = Task.await(read, 10_000)
      assert byte_size(data) == count

      assert Enum.map(1..5, fn _ -> read_offset(assert_request(5)) end) ==
               Enum.map(65..69, &(&1 * 131_072))

      SFTP.close(session)

      # A smaller in-flight bound throttles the window instead of failing it.
      fixture = backend(root, &files/2, files_state())
      {:ok, session} = open(fixture, queue_limit: 4)
      {:ok, file} = SFTP.open(session, "f")
      requests()
      assert {:ok, data} = SFTP.File.read_at(file, 0, 10 * 131_072)
      assert byte_size(data) == 10 * 131_072
      assert Enum.map(requests(), &read_offset/1) == Enum.map(0..9, &(&1 * 131_072))
      SFTP.close(session)
    end

    test "a write whose reply never arrives is uncertain and nothing more is sent",
         %{root: root} do
      fixture = backend(root, &files/2, %{files_state() | silent_write: 131_072})
      {:ok, session} = open(fixture, timeout: 300)
      {:ok, file} = SFTP.create(session, "f")
      requests()

      assert {:error, %Error{kind: :uncertain, response: %{count: 131_072}}} =
               SFTP.File.write(file, :binary.copy("x", 300_000))

      assert Enum.map(requests(), &write_offset/1) == [0, 131_072]
      assert {:ok, 131_072} = SFTP.File.seek(file, 0, :current)
      SFTP.close(session)
    end

    test "read_from reports a failed final short write, which Go ignores", %{root: root} do
      fixture = backend(root, &files/2, %{files_state() | fail_write: 131_072})
      {:ok, session} = open(fixture)
      {:ok, file} = SFTP.create(session, "f")

      assert {:error, %Error{kind: :sftp_status, error_code: 4, response: %{count: 131_082}}} =
               SFTP.File.read_from(file, [:binary.copy("x", 131_000), :binary.copy("y", 82)])

      assert {:ok, 131_072} = SFTP.File.seek(file, 0, :current)
      SFTP.close(session)
    end

    test "pipelined uploads stop at the first failure and keep its offset", %{root: root} do
      fixture = backend(root, &files/2, %{files_state() | fail_write: 2 * 131_072})
      {:ok, session} = open(fixture)
      {:ok, file} = SFTP.create(session, "f")
      requests()
      source = for _ <- 1..6, do: :binary.copy("z", 131_072)

      assert {:error, %Error{error_code: 4, response: %{count: count}}} =
               SFTP.File.read_from_with_concurrency(file, source, 2)

      offsets = Enum.map(requests(), &write_offset/1)
      assert Enum.take(offsets, 3) == [0, 131_072, 2 * 131_072]
      assert offsets == Enum.sort(offsets) and count >= 3 * 131_072
      assert {:ok, 262_144} = SFTP.File.seek(file, 0, :current)
      SFTP.close(session)
    end

    test "a raising source or sink keeps the position its completed chunks reached",
         %{root: root} do
      fixture = backend(root, &files/2, %{files_state() | size: 300_000})
      {:ok, session} = open(fixture)
      {:ok, file} = SFTP.create(session, "f")

      source =
        Stream.map([1, 2], fn
          1 -> :binary.copy("x", 131_072)
          2 -> raise "source failed"
        end)

      assert_raise RuntimeError, fn -> SFTP.File.read_from(file, source) end
      assert {:ok, 131_072} = SFTP.File.seek(file, 0, :current)

      # Go moves the offset before handing each chunk to the writer.
      {:ok, file} = SFTP.open(session, "f")

      sink = fn _ ->
        calls = Process.get(:sink_calls, 0) + 1
        Process.put(:sink_calls, calls)
        if calls == 2, do: raise("sink failed"), else: :ok
      end

      assert_raise RuntimeError, fn -> SFTP.File.write_to(file, sink) end
      assert {:ok, 262_144} = SFTP.File.seek(file, 0, :current)
      SFTP.close(session)
    end

    test "a refusing sink ends write_to with the bytes delivered", %{root: root} do
      fixture = backend(root, &files/2, %{files_state() | size: 5})
      {:ok, session} = open(fixture)
      {:ok, file} = SFTP.open(session, "f")

      assert {:error, %Error{kind: :sink_failed, response: %{count: 0}}} =
               SFTP.File.write_to(file, fn _ -> :stop end)

      SFTP.close(session)
    end

    test "sync sends fsync@openssh.com when the server announces it", %{root: root} do
      fixture =
        backend(root, &files/2, files_state(), [{"fsync@openssh.com", "1"}])

      {:ok, session} = open(fixture)
      {:ok, file} = SFTP.open(session, "f")
      requests()
      assert :ok = SFTP.File.sync(file)

      assert [<<200, _::32, 17::32, "fsync@openssh.com", 1::32, "h">>] = requests()
      SFTP.close(session)
    end
  end

  defp files_state,
    do: %{hold: false, held: [], size: 1_000_000_000, silent_write: nil, fail_write: nil}

  # A scripted file server: OPEN gives handle "h", READs return a byte per chunk
  # unless held, and STAT of "hold"/"release" controls holding.
  defp files({:request, <<type, id::32, rest::binary>>}, state) do
    case {type, rest} do
      {3, _} ->
        {[<<102, id::32, 1::32, "h">>], state}

      {5, <<1::32, "h", offset::64, length::32>>} ->
        read_reply(id, offset, length, state)

      {6, <<1::32, "h", offset::64, _::binary>>} ->
        write_reply(id, offset, state)

      {17, <<4::32, "hold">>} ->
        {[attrs(id, "hold")], %{state | hold: true}}

      {17, <<7::32, "release">>} ->
        replies =
          for {id, offset, length} <- Enum.reverse(state.held), do: data(id, offset, length)

        {replies ++ [attrs(id, "release")], %{state | hold: false, held: []}}

      {17, _} ->
        {[<<105, id::32, 5::32, state.size::64, 0o100644::32>>], state}

      {8, _} ->
        {[<<105, id::32, 1::32, state.size::64>>], state}

      _ ->
        {[status(id, 0)], state}
    end
  end

  defp read_reply(id, offset, length, state) do
    cond do
      offset >= state.size -> {[status(id, 1)], state}
      state.hold -> {[], %{state | held: [{id, offset, length} | state.held]}}
      true -> {[data(id, offset, min(length, state.size - offset))], state}
    end
  end

  defp write_reply(id, offset, state) do
    cond do
      offset == state.silent_write -> {[], state}
      offset == state.fail_write -> {[status(id, 4)], state}
      true -> {[status(id, 0)], state}
    end
  end

  defp data(id, offset, length),
    do:
      <<103, id::32, length::32,
        :binary.copy(<<rem(div(offset, 131_072), 251)>>, length)::binary>>

  defp status(id, code), do: <<101, id::32, code::32, 0::32, 0::32>>

  defp hold(session) do
    assert {:ok, _} = SFTP.stat(session, "hold")
    requests()
  end

  defp release(session) do
    assert {:ok, _} = SFTP.stat(session, "release")
    assert_receive {:sftp_request, <<17, _::32, 7::32, "release">>}
  end

  defp assert_request(type) do
    assert_receive {:sftp_request, <<^type, _::binary>> = body}, 2_000
    body
  end

  defp refute_request, do: refute_receive({:sftp_request, _}, 150)

  defp read_offset(<<5, _::32, 1::32, "h", offset::64, _::32>>), do: offset
  defp write_offset(<<6, _::32, 1::32, "h", offset::64, _::binary>>), do: offset

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

  defp backend(root, script, initial \\ nil, extensions \\ []) do
    parent = self()

    handler = fn request ->
      if request.target == "/1.0" do
        %{status: 200, body: %{type: "sync", metadata: %{api_version: "1.0", api_extensions: []}}}
      else
        %{
          upgrade: fn transport, socket ->
            serve(transport, socket, script, parent, initial, extensions)
          end
        }
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

  defp serve(transport, socket, script, parent, initial, extensions) do
    :ok =
      transport.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: sftp\r\n\r\n"
      )

    {:ok, init} = receive_frame(transport, socket)
    send(parent, {:sftp_request, init})
    pairs = for {name, data} <- extensions, into: <<>>, do: string(name) <> string(data)
    :ok = transport.send(socket, frame(<<2, 3::32, pairs::binary>>))
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
  defp string(bytes), do: <<byte_size(bytes)::32, bytes::binary>>

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
