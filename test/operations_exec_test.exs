defmodule Opsmaru.Incus.OperationsExecTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.Operations
  alias Opsmaru.Incus.Operations.Schema
  alias Opsmaru.TestSupport.{OperationsFixture, OperationsHost, WebSocketFixture}
  import OperationsFixture, only: [sync: 1, accepted: 3, operation: 3]

  @uuid "fedcba98-7654-3210-fedc-ba9876543210"
  @op "/1.0/operations/" <> @uuid
  @fds %{"0" => "s0", "1" => "s1", "2" => "s2", "control" => "scontrol"}

  setup do
    root = OperationsFixture.root()
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # A scripted exec peer: `stdout`/`stderr` bytes, `exit` status and, with
  # `hang: true`, output channels that stay open until a signal arrives.
  defp start(root, transport, opts \\ []) do
    parent = self()
    {:ok, state} = Agent.start_link(fn -> %{signal: nil} end)

    routes = fn request ->
      case {request.method, OperationsFixture.path(request), request.headers["upgrade"]} do
        {"POST", "/1.0/instances/" <> _, _} ->
          send(parent, {:exec, request.target, Jason.decode!(request.body)})
          accepted(@uuid, 103, %{"metadata" => %{"fds" => @fds}})

        {"GET", @op <> "/websocket", "websocket"} ->
          channel = String.replace_prefix(OperationsFixture.query(request)["secret"], "s", "")
          %{upgrade: fn t, s -> channel(t, s, request, channel, parent, state, opts) end}

        {"GET", @op, _} ->
          signal = Agent.get(state, & &1.signal)
          status = if signal, do: 128 + signal, else: Keyword.get(opts, :exit, 0)
          sync(operation(@uuid, 200, %{"metadata" => %{"return" => status}}))

        _ ->
          :next
      end
    end

    fixture = OperationsFixture.start(root, transport, routes, Keyword.take(opts, [:connection]))
    {fixture, %{binding: {fixture.connection, fixture.context}}}
  end

  defp channel(t, s, request, name, parent, state, opts) do
    accept =
      Base.encode64(
        :crypto.hash(
          :sha,
          request.headers["sec-websocket-key"] <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        )
      )

    :ok =
      t.send(
        s,
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
      )

    case name do
      out when out in ["1", "2"] ->
        bytes = Keyword.get(opts, if(out == "1", do: :stdout, else: :stderr), "")

        for <<chunk::binary-size(32_768) <- bytes>>,
          do: :ok = t.send(s, WebSocketFixture.frame(2, chunk))

        rest =
          binary_part(
            bytes,
            byte_size(bytes) - rem(byte_size(bytes), 32_768),
            rem(byte_size(bytes), 32_768)
          )

        if rest != "", do: :ok = t.send(s, WebSocketFixture.frame(2, rest))
        if opts[:hang], do: await_signal(state)
        :ok = t.send(s, WebSocketFixture.frame(1, ""))
        frames(t, s, name, parent, state, "")

      _ ->
        frames(t, s, name, parent, state, "")
    end
  end

  defp await_signal(state) do
    if Agent.get(state, & &1.signal), do: :ok, else: Process.sleep(20) && await_signal(state)
  end

  defp frames(t, s, name, parent, state, buffer) do
    case :cow_ws.parse_header(buffer, %{}, :undefined) do
      :more ->
        more(t, s, name, parent, state, buffer)

      {type, frag, rsv, length, mask, rest} when byte_size(rest) >= length ->
        {:ok, payload, _, rest} =
          :cow_ws.parse_payload(rest, mask, 0, 0, type, length, frag, %{}, rsv)

        case {type, name} do
          {:binary, "0"} ->
            send(parent, {:stdin, payload})

          {:text, "0"} ->
            send(parent, {:barrier, "0"})

          {:text, "control"} ->
            control = Jason.decode!(payload)
            send(parent, {:control, control})

            if control["command"] == "signal",
              do: Agent.update(state, &%{&1 | signal: control["signal"]})

          _ ->
            :ok
        end

        if type != :close, do: frames(t, s, name, parent, state, rest)

      _ ->
        more(t, s, name, parent, state, buffer)
    end
  end

  defp more(t, s, name, parent, state, buffer) do
    case t.recv(s, 0, 10_000) do
      {:ok, bytes} -> frames(t, s, name, parent, state, buffer <> bytes)
      _ -> :ok
    end
  end

  defp run(input, caller),
    do:
      Operations.run("incus_instance_exec", input,
        host: OperationsHost,
        caller: caller,
        scopes: ["incus.exec"]
      )

  defp valid!(result) do
    {:ok, descriptor} = Operations.fetch("incus_instance_exec")
    assert :ok = Schema.validate(Operations.output_schema(descriptor), result)
    result
  end

  for transport <- [:gen_tcp, :ssl] do
    test "runs a noninteractive command with stdin and exit status over #{transport}", %{
      root: root
    } do
      {_fixture, caller} =
        start(root, unquote(transport), stdout: "hello\n", stderr: "warn\n", exit: 3)

      input = %{
        "instance" => "web",
        "command" => ["sh", "-c", "cat; exit 3"],
        "environment" => %{"A" => "1"},
        "cwd" => "/root",
        "user" => 1000,
        "group" => 1000,
        "stdin" => "input-bytes"
      }

      assert {:ok, result} = run(input, caller)
      valid!(result)

      assert %{
               "status" => "completed",
               "operation_id" => @uuid,
               "exit_status" => 3,
               "stdout" => "hello\n",
               "stdout_encoding" => "utf-8",
               "stdout_bytes" => 6,
               "stdout_truncated" => false,
               "stderr" => "warn\n",
               "timed_out" => false,
               "output_limited" => false
             } = result

      assert_received {:exec, "/1.0/instances/web/exec", body}

      assert body == %{
               "command" => ["sh", "-c", "cat; exit 3"],
               "wait-for-websocket" => true,
               "interactive" => false,
               "record-output" => false,
               "environment" => %{"A" => "1"},
               "width" => 0,
               "height" => 0,
               "cwd" => "/root",
               "user" => 1000,
               "group" => 1000
             }

      assert_receive {:stdin, "input-bytes"}, 5_000
      assert_receive {:barrier, "0"}, 5_000
      refute_received {:control, _}
    end
  end

  test "output beyond 64 KiB per stream is truncated with an explicit indicator", %{root: root} do
    stdout = String.duplicate("a", 100_000)
    stderr = :binary.copy(<<255, 0>>, 40_000)
    {_fixture, caller} = start(root, :gen_tcp, stdout: stdout, stderr: stderr)

    assert {:ok, result} = run(%{"instance" => "web", "command" => ["yes"]}, caller)
    valid!(result)

    assert %{"stdout_bytes" => 100_000, "stdout_truncated" => true, "stdout_encoding" => "utf-8"} =
             result

    assert result["stdout"] == binary_part(stdout, 0, 65_536)

    assert %{"stderr_bytes" => 80_000, "stderr_truncated" => true, "stderr_encoding" => "base64"} =
             result

    assert Base.decode64!(result["stderr"]) == binary_part(stderr, 0, 65_536)
  end

  test "a truncated UTF-8 sequence is trimmed instead of switching to base64", %{root: root} do
    stdout = String.duplicate("a", 65_535) <> "é" <> "tail"
    {_fixture, caller} = start(root, :gen_tcp, stdout: stdout)

    assert {:ok, %{"stdout" => text, "stdout_encoding" => "utf-8", "stdout_truncated" => true}} =
             run(%{"instance" => "web", "command" => ["x"]}, caller)

    assert text == String.duplicate("a", 65_535)
  end

  test "a command still running at the timeout is killed and reported", %{root: root} do
    {_fixture, caller} = start(root, :gen_tcp, stdout: "started\n", hang: true)

    {elapsed, result} =
      :timer.tc(fn ->
        run(
          %{"instance" => "web", "command" => ["sleep", "1000"], "timeout_seconds" => 1},
          caller
        )
      end)

    assert {:ok,
            %{
              "timed_out" => true,
              "exit_status" => 137,
              "status" => "completed",
              "stdout" => "started\n"
            } = result} =
             result

    valid!(result)
    assert_received {:control, %{"command" => "signal", "signal" => 9}}
    assert div(elapsed, 1000) in 900..6_000
  end

  test "total output past the stream cap kills the command", %{root: root} do
    {_fixture, caller} =
      start(root, :gen_tcp,
        stdout: String.duplicate("z", 300_000),
        hang: true,
        connection: [max_stream_bytes: 400_000]
      )

    assert {:ok,
            %{
              "output_limited" => true,
              "timed_out" => false,
              "exit_status" => 137,
              "stdout_bytes" => 300_000
            }} =
             run(%{"instance" => "web", "command" => ["yes"], "timeout_seconds" => 30}, caller)

    assert_received {:control, %{"command" => "signal", "signal" => 9}}
  end

  test "the duration is capped by the host stream timeout", %{root: root} do
    {_fixture, caller} = start(root, :gen_tcp, connection: [stream_timeout: 8_000])

    assert {:ok, %{"timeout_seconds" => 3}} =
             run(%{"instance" => "web", "command" => ["true"], "timeout_seconds" => 300}, caller)

    {_fixture, caller} = start(root, :gen_tcp, connection: [stream_timeout: 5_500])

    assert {:error, %{"kind" => "invalid_input"}} =
             run(%{"instance" => "web", "command" => ["true"]}, caller)
  end

  test "argv, environment, cwd and stdin bounds reject before any request", %{root: root} do
    {fixture, caller} = start(root, :gen_tcp)

    for input <- [
          %{"command" => []},
          %{"command" => List.duplicate("a", 65)},
          %{"command" => [String.duplicate("a", 4097)]},
          %{"command" => ["a"], "environment" => Map.new(1..65, &{"K#{&1}", "v"})},
          %{"command" => ["a"], "environment" => %{"K" => String.duplicate("v", 4097)}},
          %{"command" => ["a"], "cwd" => "relative"},
          %{"command" => ["a"], "stdin" => String.duplicate("é", 40_000)},
          %{"command" => ["a"], "user" => -1},
          %{"command" => ["a"], "timeout_seconds" => 301},
          %{"command" => ["a"], "interactive" => true},
          %{"command" => ["a"], "width" => 80}
        ] do
      assert {:error, %{"kind" => "invalid_input"}} =
               run(Map.put(input, "instance", "web"), caller)
    end

    assert {:error, %{"kind" => "invalid_input", "path" => "/instance"}} =
             run(%{"command" => ["a"]}, caller)

    assert OperationsFixture.requests(fixture) == []
  end

  test "other requests stay responsive while a command runs", %{root: root} do
    {_fixture, caller} = start(root, :gen_tcp, hang: true)

    exec =
      Task.async(fn ->
        run(%{"instance" => "web", "command" => ["sleep", "9"], "timeout_seconds" => 2}, caller)
      end)

    assert_receive {:exec, _, _}, 5_000

    assert {:ok, %{"item" => %{"api_version" => "1.0"}}} =
             Operations.run("incus_server_get", %{},
               host: OperationsHost,
               caller: caller,
               scopes: ["incus.read"]
             )

    assert {:ok, %{"timed_out" => true}} = Task.await(exec, 10_000)
  end
end
