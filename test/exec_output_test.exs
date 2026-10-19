defmodule Opsmaru.Incus.ExecOutputTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Operation, RequestContext, Server, Session}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture, WireComparison}
  @driver Path.expand("../.integration/exec-io-driver", __DIR__)
  @body %{
    "command" => ["fixture-command"],
    "wait-for-websocket" => true,
    "interactive" => false,
    "record-output" => false,
    "environment" => %{"EXEC_FIXTURE" => "value"},
    "cwd" => "",
    "user" => 0,
    "group" => 0,
    "width" => 0,
    "height" => 0
  }
  @stdout <<0, 255, 128, 10>>
  @stderr <<254, 0, 13>>

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./execio"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-exec-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:gen_tcp, :ssl] do
    test "actual native noninteractive IO and exit status match over #{transport}", %{root: root} do
      {client, fixture, credentials} = fixture(root, unquote(transport))
      stdin = <<255, 0, 42>>

      input =
        Map.merge(credentials, %{
          Project: "p1",
          Member: "m1",
          Stdin: Base.encode64(stdin),
          Body: @body
        })

      file = Path.join(root, "input.json")
      File.write!(file, Jason.encode!(input))
      File.chmod!(file, 0o600)

      {out, 0} =
        System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "exec-fixture", @driver, file],
          stderr_to_stdout: true
        )

      native = Jason.decode!(out)
      refute native["error"]
      assert_receive {:stdin, ^stdin}, 5_000
      assert_receive {:barrier, "0"}, 5_000
      assert {:ok, session} = Session.exec(client, "fixture", @body)
      assert :ok = Session.input(session, stdin)
      parent = self()

      assert {:ok, result} =
               Session.collect(
                 session,
                 &send_chunk(parent, :stdout, &1),
                 &send_chunk(parent, :stderr, &1)
               )

      assert_receive {:stdout, @stdout}, 5_000
      assert_receive {:stderr, @stderr}, 5_000
      assert_receive {:stdin, ^stdin}, 5_000
      assert_receive {:barrier, "0"}, 5_000
      assert result.stdout_bytes == byte_size(@stdout)
      assert result.stderr_bytes == byte_size(@stderr)
      assert Base.decode64!(native["stdout"]) == @stdout
      assert Base.decode64!(native["stderr"]) == @stderr
      assert Operation.data(result.operation)["id"] == native["operation"]["id"]
      assert result.exit_status == native["operation"]["metadata"]["return"]
      assert result.exit_status == 7
      assert_closed(session)

      assert {:ok, run} =
               Session.run(
                 client,
                 "fixture",
                 @body,
                 stdin,
                 &send_chunk(parent, :stdout, &1),
                 &send_chunk(parent, :stderr, &1)
               )

      assert_receive {:stdout, @stdout}, 5_000
      assert_receive {:stderr, @stderr}, 5_000
      assert_receive {:stdin, ^stdin}, 5_000
      assert_receive {:barrier, "0"}, 5_000
      assert run.exit_status == result.exit_status
      assert run.stdout_bytes == result.stdout_bytes and run.stderr_bytes == result.stderr_bytes
      assert run.operation.client == client
      assert run.operation.response.connection == client.connection
      requests = HTTPFixture.requests(fixture)
      posts = Enum.filter(requests, &(&1.method == "POST"))
      assert length(posts) == 3
      assert Enum.all?(posts, &(&1.target == "/1.0/instances/fixture/exec?project=p1&target=m1"))
      assert Enum.map(posts, &Jason.decode!(&1.body)) |> Enum.uniq() == [@body]
      refute Enum.any?(requests, &(&1.method == "DELETE"))
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "ExecInstance modes agree with the pinned client over #{transport}", %{root: root} do
      parent = self()
      stdin = <<255, 0, 42>>
      nowait = %{@body | "wait-for-websocket" => false}

      sized =
        Map.merge(@body, %{
          "user" => 1000,
          "group" => 1000,
          "cwd" => "/srv",
          "width" => 80,
          "height" => 24
        })

      for {mode, body, opts} <- [
            {"collect", sized, [extensions: ["container_exec_user_group_cwd"]]},
            {"empty", @body, [empty: true, metadata: %{"return" => 0}]},
            {"submit", nowait, [fds: :none]},
            {"submit", %{nowait | "record-output" => true},
             [fds: :none, extensions: ["container_exec_recording"]]},
            {"interactive", %{@body | "interactive" => true, "width" => 80, "height" => 24},
             [fds: %{"0" => "0", "control" => "control"}, interactive: true]}
          ] do
        {client, fixture, credentials} = fixture(root, unquote(transport), opts)
        native = go_exec(root, credentials, String.replace(mode, "empty", "collect"), body, stdin)
        refute native["error"]
        assert native["operation"]["id"] == "exec-id"
        go = exchange(HTTPFixture.requests(fixture))
        if mode != "submit", do: assert_exchanged(stdin)
        go_control = if mode == "interactive", do: controls()
        stdout = &send_chunk(parent, :stdout_sink, &1)
        stderr = &send_chunk(parent, :stderr_sink, &1)

        case mode do
          "submit" ->
            assert {:ok, reply} =
                     Incus.call(client, "ExecInstance", %{"instanceName" => "fixture"},
                       body: body
                     )

            assert reply.operation == "/1.0/operations/exec-id"
            assert reply.metadata.data["id"] == native["operation"]["id"]
            assert {:ok, session} = Session.exec(client, "fixture", body)
            assert session.channels == %{} and not session.collectable?

            assert {:error, %Error{kind: :invalid_exec_collection}} =
                     Session.collect(session, stdout, stderr)

            assert {:error, %Error{kind: :invalid_exec_run}} =
                     Session.run(client, "fixture", body, "", stdout, stderr)

          "interactive" ->
            assert {:ok, session} = Session.exec(client, "fixture", body)
            refute session.collectable?
            assert Enum.sort(Map.keys(session.channels)) == ["0", "control"]
            assert :ok = Session.input(session, stdin)
            assert :ok = Session.resize(session, 80, 24)
            assert :ok = Session.signal(session, 15)

            # Local control bounds reject before any frame is written.
            for {function, args} <- [
                  resize: [0, 24],
                  resize: [80, 65_536],
                  signal: [0],
                  signal: [65]
                ],
                do:
                  assert_raise(FunctionClauseError, fn ->
                    apply(Session, function, [session | args])
                  end)

            assert :ok = Session.close_input(session)
            assert {:ok, {:binary, @stdout}} = Session.output(session, "0")
            assert Base.decode64!(native["stdout"]) == @stdout
            assert {:ok, 7} = Session.exit_status(session)
            assert native["operation"]["metadata"]["return"] == 7
            assert_exchanged(stdin)
            assert controls() == go_control
            refute_receive {:control, _}
            assert :ok = Session.close(session)

          _ ->
            assert {:ok, result} = Session.run(client, "fixture", body, stdin, stdout, stderr)
            assert result.exit_status == native["operation"]["metadata"]["return"]
            assert result.stdout_bytes == byte_size(Base.decode64!(native["stdout"] || ""))
            assert result.stderr_bytes == byte_size(Base.decode64!(native["stderr"] || ""))

            if mode == "empty" do
              refute_received {:stdout_sink, _}
              refute_received {:stderr_sink, _}
            else
              assert_received {:stdout_sink, @stdout}
              assert_received {:stderr_sink, @stderr}
            end

            assert_exchanged(stdin)
        end

        requests = HTTPFixture.requests(fixture)
        elixir = exchange(Enum.drop(requests, length(go.requests)))
        [expected] = go.posts
        assert elixir.posts != []
        assert Enum.all?(elixir.posts, &(WireComparison.compare(expected, &1) == :ok))
        assert expected["body"] == body
        assert expected["query"] == %{"project" => "p1", "target" => "m1"}
        # Pinned GetOperationWebsocket sends only the secret; the host routing added to
        # each upgrade is ignored by the pinned daemon's operation WebSocket handler.
        assert elixir.upgrades ==
                 Enum.map(go.upgrades, fn {path, query} ->
                   {path, Map.merge(query, %{"project" => "p1", "target" => "m1"})}
                 end)

        assert Enum.all?(go.upgrades, fn {path, query} ->
                 path == "/1.0/operations/exec-id/websocket" and Map.keys(query) == ["secret"]
               end)

        fds = Keyword.get(opts, :fds, %{"0" => "0", "1" => "1", "2" => "2"})
        expected_secrets = if fds == :none, do: [], else: Enum.sort(Map.values(fds))
        assert Enum.map(go.upgrades, fn {_, query} -> query["secret"] end) == expected_secrets
        refute Enum.any?(requests, &(&1.method == "DELETE"))
      end
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "exec extension guards reject before dispatch like the pinned client over #{transport}",
         %{root: root} do
      {client, fixture, credentials} = fixture(root, unquote(transport))
      sink = fn _ -> :ok end

      for {field, value, extension} <- [
            {"record-output", true, "container_exec_recording"},
            {"user", 1000, "container_exec_user_group_cwd"},
            {"group", 1000, "container_exec_user_group_cwd"},
            {"cwd", "/srv", "container_exec_user_group_cwd"}
          ] do
        body = Map.put(@body, field, value)
        native = go_exec(root, credentials, "submit", body)

        assert native["error"] ==
                 "The server is missing the required \"#{extension}\" API extension"

        assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
                 Incus.call(client, "ExecInstance", %{"instanceName" => "fixture"}, body: body)

        assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
                 Session.exec(client, "fixture", body)

        result = Session.run(client, "fixture", body, "", sink, sink)

        if field == "record-output",
          do: assert({:error, %Error{kind: :invalid_exec_run}} = result),
          else:
            assert(
              {:error,
               %Error{kind: :unsupported_extension, extension: ^extension, operation: nil}} =
                result
            )
      end

      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method != "GET"))
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "native exec rejection agrees with the pinned client through exec and run over #{transport}",
         %{root: root} do
      sink = fn _ -> :ok end

      for status <- [400, 403, 404] do
        {client, fixture, credentials} = fixture(root, unquote(transport), post_error: status)
        native = go_exec(root, credentials, "collect", @body)
        assert native["error"] == "native #{status}"

        for result <- [
              Session.exec(client, "fixture", @body),
              Session.run(client, "fixture", @body, "", sink, sink)
            ] do
          assert {:error,
                  %Error{
                    kind: :native,
                    http_status: ^status,
                    error_code: ^status,
                    message: message,
                    operation: operation
                  }} = result

          # The native error envelope names no operation: nothing was accepted.
          assert message == native["error"] and operation in [nil, ""]
        end

        requests = HTTPFixture.requests(fixture)
        assert Enum.count(requests, &(&1.method == "POST")) == 3
        assert Enum.all?(requests, &(&1.method == "POST" or URI.parse(&1.target).path == "/1.0"))
      end
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "channel negotiation and metadata failures retain acceptance and close opened peers over #{transport}",
         %{root: root} do
      sink = fn _ -> :ok end
      secrets = %{"0" => "secret-0", "1" => "secret-1", "2" => "secret-2"}
      {client, fixture, _} = fixture(root, unquote(transport), reject_upgrade: "2", fds: secrets)

      for result <- [
            Session.exec(client, "fixture", @body),
            Session.run(client, "fixture", @body, "", sink, sink)
          ] do
        assert {:error, %Error{kind: :stream_negotiation, operation: url} = error} = result
        assert url == "/1.0/operations/exec-id"
        refute inspect(error) =~ "secret-"
        for name <- ["0", "1"], do: assert_receive({:peer_closed, ^name}, 5_000)
      end

      upgrades = exchange(HTTPFixture.requests(fixture)).upgrades
      assert length(upgrades) == 6

      assert Enum.all?(upgrades, fn {path, query} ->
               path == "/1.0/operations/exec-id/websocket" and
                 query["secret"] in Map.values(secrets)
             end)

      for fds <- [
            %{"0" => "0", "3" => "3"},
            %{"0" => 0},
            %{"0" => ""},
            %{"0" => String.duplicate("a", 4097)},
            Map.new(1..9, &{"#{&1}", "x"}),
            "secret"
          ] do
        {client, fixture, _} = fixture(root, unquote(transport), fds: fds)

        for result <- [
              Session.exec(client, "fixture", @body),
              Session.run(client, "fixture", @body, "", sink, sink)
            ] do
          assert {:error, %Error{kind: :invalid_stream_metadata, operation: url}} = result
          assert url == "/1.0/operations/exec-id"
        end

        requests = HTTPFixture.requests(fixture)
        assert Enum.map(requests, & &1.method) == ["POST", "POST"]
      end
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "pending exit status, missing channels and Inspect redaction over #{transport}", %{
      root: root
    } do
      secrets = %{"0" => "secret-0", "1" => "secret-1", "2" => "secret-2"}
      {client, fixture, _} = fixture(root, unquote(transport), status: 103, fds: secrets)
      {:ok, session} = Session.exec(client, "fixture", @body)
      assert inspect(session) == "#Opsmaru.Incus.Session<native channels redacted>"
      refute inspect([session, session.operation, session.channels]) =~ "secret-"

      assert {:error, %Error{kind: :operation_pending, operation: url} = error} =
               Session.exit_status(session)

      assert url == session.operation.url
      refute inspect(error) =~ "secret-"

      for result <- [
            Session.resize(session, 80, 24),
            Session.signal(session, 15),
            Session.output(session, "control", 100),
            Session.output(session, "3", 100)
          ],
          do: assert({:error, %Error{kind: :missing_channel}} = result)

      assert :ok = Session.close(session)
      for name <- ["0", "1", "2"], do: assert_receive({:peer_closed, ^name}, 5_000)
      {client, _, _} = fixture(root, unquote(transport), fds: :none)
      nowait = %{@body | "wait-for-websocket" => false}
      {:ok, session} = Session.exec(client, "fixture", nowait)

      for result <- [
            Session.input(session, "x"),
            Session.close_input(session),
            Session.output(session, "1", 100)
          ],
          do: assert({:error, %Error{kind: :missing_channel}} = result)

      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "run chunks stdin to the smaller response frame limit over #{transport}", %{root: root} do
      {client, fixture, _} = fixture(root, unquote(transport))
      client = %{client | connection: %{client.connection | max_response_bytes: 4096}}
      assert client.connection.max_chunk_bytes == 65_536
      chunk = :binary.copy(<<0, 255>>, 2048)
      stdin = chunk <> chunk
      sink = fn _ -> :ok end

      assert {:ok, result} =
               Session.run(client, "fixture", @body, stdin, sink, sink,
                 max_input_bytes: byte_size(stdin),
                 max_output_bytes: 7
               )

      assert result.exit_status == 7
      assert result.stdout_bytes == 4 and result.stderr_bytes == 3
      assert result.operation.client == client
      assert_receive {:stdin, ^chunk}, 5_000
      assert_receive {:stdin, ^chunk}, 5_000
      assert_receive {:barrier, "0"}, 5_000
      requests = HTTPFixture.requests(fixture)
      assert Enum.count(requests, &(&1.method == "POST")) == 1
      refute Enum.any?(requests, &(&1.method == "DELETE"))
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "run preflight rejects mode, sinks, options and input limits without POST over #{transport}",
         %{root: root} do
      {client, fixture, _} = fixture(root, unquote(transport))
      sink = fn _ -> :ok end

      for {body, stdin, stdout, opts, kind} <- [
            {Map.put(@body, "interactive", true), "", sink, [], :invalid_exec_run},
            {Map.put(@body, "record-output", true), "", sink, [], :invalid_exec_run},
            {Map.delete(@body, "wait-for-websocket"), "", sink, [], :invalid_exec_run},
            {@body, [], sink, [], :invalid_exec_run},
            {@body, "", nil, [], :invalid_exec_run},
            {@body, "", sink, [timeout: 0], :invalid_exec_run},
            {@body, "", sink, [timeout: 1, timeout: 2], :invalid_exec_run},
            {@body, "", sink, [unknown: true], :invalid_exec_run},
            {@body, "", sink, [max_output_bytes: 0], :invalid_exec_run},
            {@body, "ab", sink, [max_input_bytes: 1], :exec_input_limit}
          ] do
        assert {:error, %Error{kind: ^kind, operation: nil}} =
                 Session.run(client, "fixture", body, stdin, stdout, sink, opts)
      end

      assert HTTPFixture.requests(fixture) == []
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "run drains both outputs while stdin is blocked and waits for the input barrier over #{transport}",
         %{
           root: root
         } do
      {client, fixture, _} = fixture(root, unquote(transport), input_gate: true)
      client = %{client | connection: %{client.connection | max_chunk_bytes: 4096}}
      parent = self()
      stdin = :binary.copy(<<0, 255>>, 2_097_152)

      runner =
        Task.async(fn ->
          Session.run(
            client,
            "fixture",
            @body,
            stdin,
            &send_chunk(parent, :stdout, &1),
            &send_chunk(parent, :stderr, &1),
            max_input_bytes: byte_size(stdin),
            max_output_bytes: 7,
            timeout: 15_000
          )
        end)

      assert_receive {:input_gate, peer}, 5_000
      assert_receive {:stdout, @stdout}, 5_000
      assert_receive {:stderr, @stderr}, 5_000

      refute Enum.any?(
               HTTPFixture.requests(fixture),
               &(&1.method == "GET" and not String.contains?(&1.target, "websocket"))
             )

      send(peer, :release_input)

      assert {:ok, %{stdout_bytes: 4, stderr_bytes: 3, exit_status: 7}} =
               Task.await(runner, 20_000)

      received =
        for _ <- 1..1024 do
          assert_receive {:stdin, chunk}, 5_000
          assert byte_size(chunk) == 4096
          chunk
        end

      assert IO.iodata_to_binary(received) == stdin
      assert_receive {:barrier, "0"}, 5_000
      for name <- ["0", "1", "2"], do: assert_receive({:peer_closed, ^name}, 5_000)
    end
  end

  for mode <- [:deadline, :cancellation], transport <- [:gen_tcp, :ssl] do
    test "run #{mode} interrupts a confirmed blocked stdin write over #{transport}", %{root: root} do
      {client, fixture, _} =
        fixture(root, unquote(transport), input_gate: true, control: true, read_timeout: 30_000)

      context = RequestContext.new!(timeout: 60_000)
      client = Incus.with_context(client, context)

      client = %{
        client
        | connection: %{client.connection | timeout: 30_000, max_chunk_bytes: 1_048_576}
      }

      parent = self()
      stdin = :binary.copy(<<0, 255>>, 2_097_152)
      timeout = if unquote(mode) == :deadline, do: 10_000, else: 30_000

      runner =
        Task.async(fn ->
          receive do
            :start -> :ok
          end

          Session.run(
            client,
            "fixture",
            @body,
            stdin,
            &send_chunk(parent, :stdout, &1),
            &send_chunk(parent, :stderr, &1),
            timeout: timeout
          )
        end)

      # Observe only this call's descendants; capture the real channel handles.
      Code.ensure_loaded!(Session)
      :erlang.trace(runner.pid, true, [:call, :set_on_spawn])

      assert :erlang.trace_pattern({Session, :exec, 4}, [{:_, [], [{:return_trace}]}], [:local]) ==
               1

      try do
        send(runner.pid, :start)
        assert_receive {:input_gate, peer}, 5_000
        assert_receive {:trace, _, :return_from, {Session, :exec, 4}, {:ok, session}}, 5_000
        assert_receive {:stdout, @stdout}, 5_000
        assert_receive {:stderr, @stderr}, 5_000

        await_blocked_stdin(
          session.channels["0"].pid,
          System.monotonic_time(:millisecond) + 5_000
        )

        monitors = for {_, channel} <- session.channels, do: Process.monitor(channel.pid)
        if unquote(mode) == :cancellation, do: RequestContext.cancel(context)
        expected = if unquote(mode) == :deadline, do: :deadline, else: :canceled

        assert {:error, %Error{kind: ^expected, operation: url, response: response}} =
                 Task.await(runner, 20_000)

        assert url == session.operation.url

        assert response.connection == client.connection and
                 response.identity == client.context.identity

        for monitor <- monitors, do: assert_receive({:DOWN, ^monitor, :process, _, _}, 5_000)
        assert_closed(session)
        send(peer, :release_input)
        for name <- ["0", "1", "2", "control"], do: assert_receive({:peer_closed, ^name}, 5_000)
        refute_receive {:barrier, "0"}
        requests = HTTPFixture.requests(fixture)
        assert Enum.count(requests, &(&1.method == "POST")) == 1
        refute Enum.any?(requests, &(&1.method == "DELETE"))
        refute Enum.any?(requests, &(&1.method == "GET" and URI.parse(&1.target).path == url))

        if unquote(mode) == :deadline do
          assert RequestContext.status(context) == :active

          assert {:ok, _} =
                   Operation.poll(%Operation{client: client, url: url, response: response})
        else
          assert RequestContext.status(context) == :canceled
        end
      after
        :erlang.trace_pattern({Session, :exec, 4}, false, [:local])
        if Process.alive?(runner.pid), do: Task.shutdown(runner, :brutal_kill)
      end
    end
  end

  defp await_blocked_stdin(pid, deadline) do
    unless blocked_send?(pid, true) do
      assert System.monotonic_time(:millisecond) < deadline,
             inspect(Process.info(pid, :current_stacktrace))

      Process.sleep(10)
      await_blocked_stdin(pid, deadline)
    end
  end

  # Unix channels block in the socket send; TLS channels wait on a monitored
  # TLS sender while that sender blocks in the socket send.
  defp blocked_send?(pid, follow?) do
    state = Process.info(pid, [:current_stacktrace, :status, :monitors]) || []

    calls =
      for {module, function, _, _} <- state[:current_stacktrace] || [], do: {module, function}

    state[:status] == :waiting and
      ({:prim_inet, :send} in calls or
         (follow? and {:tls_sender, :call} in calls and
            Enum.any?(state[:monitors], fn
              {:process, sender} when is_pid(sender) -> blocked_send?(sender, false)
              _ -> false
            end)))
  end

  for transport <- [:gen_tcp, :ssl] do
    test "run lifetime includes submission and negotiation with truthful retained acceptance over #{transport}",
         %{
           root: root
         } do
      sink = fn _ -> :ok end

      for {gate, kind, operation} <- [
            {:post_gate, :uncertain, nil},
            {:upgrade_gate, :deadline, "/1.0/operations/exec-id"}
          ] do
        {client, fixture, _} = fixture(root, unquote(transport), [{gate, true}])

        assert {:error, %Error{kind: ^kind, operation: ^operation, response: response}} =
                 Session.run(client, "fixture", @body, "", sink, sink, timeout: 1_000)

        if operation do
          assert response.connection == client.connection
          assert response.identity == client.context.identity
        end

        assert_receive {:request_gate, peer}, 5_000
        send(peer, :release_request)
        assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 1
        refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
      end
    end
  end

  for mode <- [:deadline, :cancellation], transport <- [:gen_tcp, :ssl] do
    test "request context #{mode} during a channel upgrade keeps its kind and acceptance over #{transport}",
         %{root: root} do
      {client, fixture, _} = fixture(root, unquote(transport), upgrade_gate: true)
      timeout = if unquote(mode) == :deadline, do: 1_000, else: 15_000
      context = RequestContext.new!(timeout: timeout)
      client = Incus.with_context(client, context)
      exec = Task.async(fn -> Session.exec(client, "fixture", @body) end)

      # The upgrade stays pending, so only the context watcher can end the channel.
      assert_receive {:request_gate, peer}, 5_000
      if unquote(mode) == :cancellation, do: RequestContext.cancel(context)
      expected = if unquote(mode) == :deadline, do: :deadline, else: :canceled

      assert {:error, %Error{kind: ^expected, operation: url, response: response}} =
               Task.await(exec, 10_000)

      assert url == "/1.0/operations/exec-id" and response.connection == client.connection
      assert RequestContext.status(context) == expected
      send(peer, :release_request)
      requests = HTTPFixture.requests(fixture)
      assert Enum.count(requests, &(&1.method == "POST")) == 1
      assert Enum.count(requests, &(&1.headers["upgrade"] == "websocket")) == 1
      refute Enum.any?(requests, &(&1.method == "DELETE"))
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "run local timeout and host cancellation kill stalled sinks and retain a reusable handle over #{transport}",
         %{root: root} do
      for mode <- [:local_deadline, :host_deadline, :cancellation] do
        {client, fixture, _} = fixture(root, unquote(transport))

        context =
          RequestContext.new!(timeout: if(mode == :host_deadline, do: 1_000, else: 15_000))

        client = Incus.with_context(client, context)
        parent = self()

        sink = fn _ ->
          Process.flag(:trap_exit, true)
          send(parent, {:sink, self()})
          if mode == :cancellation, do: RequestContext.cancel(context)

          receive do
            :never -> :ok
          end
        end

        expected = if mode == :cancellation, do: :canceled, else: :deadline

        assert {:error, %Error{kind: ^expected, operation: url, response: response}} =
                 Session.run(client, "fixture", @body, "", sink, sink,
                   timeout: if(mode == :host_deadline, do: 10_000, else: 1_000)
                 )

        assert url == "/1.0/operations/exec-id" and response.connection == client.connection
        assert_receive {:sink, worker}, 5_000
        monitor = Process.monitor(worker)
        assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
        for name <- ["0", "1", "2"], do: assert_receive({:peer_closed, ^name}, 5_000)

        if mode == :local_deadline do
          assert RequestContext.status(context) == :active

          assert {:ok, _} =
                   Operation.poll(%Operation{client: client, url: url, response: response})
        end

        assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 1
        refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
      end
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "run owner loss terminates the sink and all peers without DELETE over #{transport}", %{
      root: root
    } do
      {client, fixture, _} = fixture(root, unquote(transport), control: true)
      parent = self()

      owner =
        spawn(fn ->
          sink = fn _ ->
            Process.flag(:trap_exit, true)
            send(parent, {:sink, self()})

            receive do
              :never -> :ok
            end
          end

          Session.run(client, "fixture", @body, "", sink, sink)
        end)

      assert_receive {:sink, worker}, 5_000
      monitor = Process.monitor(worker)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
      for name <- ["0", "1", "2", "control"], do: assert_receive({:peer_closed, ^name}, 5_000)
      assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 1
      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "limits and rejected/raising sinks retain acceptance and close all channels over #{transport}",
         %{root: root} do
      {client, fixture, _} = fixture(root, unquote(transport))

      for {opts, sink, kind} <- [
            {[max_output_bytes: 6], fn _ -> :ok end, :exec_output_limit},
            {[], fn _ -> :no end, :sink_rejected},
            {[], fn _ -> raise "private sink detail" end, :sink_rejected}
          ] do
        {:ok, session} = Session.exec(client, "fixture", @body)

        assert {:error, %Error{kind: ^kind, operation: url, response: response} = error} =
                 Session.collect(session, sink, sink, opts)

        assert url == session.operation.url and response == session.operation.response
        refute inspect(error) =~ "private"
        assert_closed(session)

        assert {:error, %Error{kind: ^kind, operation: ^url, response: accepted}} =
                 Session.run(client, "fixture", @body, "", sink, sink, opts)

        assert accepted.connection == client.connection
      end

      assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 6
      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "output barriers cannot substitute for final operation or valid exit metadata over #{transport}",
         %{
           root: root
         } do
      for {status, metadata, kind} <- [
            {103, %{"return" => 7}, :deadline},
            {400, %{}, :operation_failed},
            {200, %{}, :invalid_exec_status},
            {200, "malformed", :invalid_operation}
          ] do
        {client, _, _} = fixture(root, unquote(transport), status: status, metadata: metadata)
        {:ok, session} = Session.exec(client, "fixture", @body)

        assert {:error, %Error{kind: ^kind, operation: url}} =
                 Session.collect(session, fn _ -> :ok end, fn _ -> :ok end,
                   timeout: if(status == 103, do: 1_000, else: 5_000)
                 )

        assert url == session.operation.url
        assert_closed(session)
      end
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "a stalled callback is bounded and killed, including exit trapping over #{transport}", %{
      root: root
    } do
      {client, _, _} = fixture(root, unquote(transport))
      context = RequestContext.new!(timeout: 10_000)
      client = Incus.with_context(client, context)
      {:ok, session} = Session.exec(client, "fixture", @body)
      parent = self()

      sink = fn _ ->
        Process.flag(:trap_exit, true)
        send(parent, {:sink, self()})

        receive do
          :never -> :ok
        end
      end

      assert {:error, %Error{kind: :deadline, operation: url}} =
               Session.collect(session, sink, sink, timeout: 1_000)

      assert url == session.operation.url
      assert_receive {:sink, worker}, 5_000
      refute Process.alive?(worker)
      assert_closed(session)
      assert RequestContext.status(context) == :active
      assert {:ok, _} = Operation.poll(session.operation)
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "foreign creator and malformed options reject without touching channels over #{transport}",
         %{root: root} do
      {client, fixture, _} = fixture(root, unquote(transport))
      {:ok, session} = Session.exec(client, "fixture", @body)
      before = HTTPFixture.requests(fixture)
      sink = fn _ -> :ok end

      assert {:error, %Error{kind: :invalid_exec_collection}} =
               Task.async(fn -> Session.collect(session, sink, sink) end) |> Task.await()

      for opts <- [
            [timeout: 0],
            [timeout: 10, timeout: 20],
            [max_output_bytes: 0],
            [unknown: 1],
            [{:timeout, 1} | :bad]
          ] do
        assert {:error, %Error{kind: :invalid_exec_collection}} =
                 Session.collect(session, sink, sink, opts)
      end

      assert {:error, %Error{kind: :invalid_exec_collection}} =
               Session.collect(%{session | collectable?: false}, sink, sink)

      assert Enum.all?(session.channels, fn {_, c} -> Process.alive?(c.pid) end)
      assert HTTPFixture.requests(fixture) == before
      Session.close(session)
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "host cancellation interrupts stalled sinks over #{transport}", %{root: root} do
      {client, _, _} = fixture(root, unquote(transport))
      context = RequestContext.new!(timeout: 10_000)
      client = Incus.with_context(client, context)
      {:ok, session} = Session.exec(client, "fixture", @body)

      sink = fn _ ->
        RequestContext.cancel(context)

        receive do
          :never -> :ok
        end
      end

      assert {:error, %Error{kind: :canceled}} = Session.collect(session, sink, sink)
      assert_closed(session)
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "owner loss kills an exit-trapping sink and all channels without remote cancellation over #{transport}",
         %{
           root: root
         } do
      {client, fixture, _} = fixture(root, unquote(transport), control: true)
      parent = self()

      owner =
        spawn(fn ->
          {:ok, session} = Session.exec(client, "fixture", @body)
          send(parent, {:session, session})

          sink = fn _ ->
            Process.flag(:trap_exit, true)
            send(parent, {:worker, self()})

            receive do
              :never -> :ok
            end
          end

          Session.collect(session, sink, sink)
        end)

      assert_receive {:session, session}, 5_000
      assert_receive {:worker, worker}, 5_000

      monitors =
        Enum.map(
          [worker | Enum.map(session.channels, fn {_, c} -> c.pid end)],
          &Process.monitor/1
        )

      Process.exit(owner, :kill)
      for monitor <- monitors, do: assert_receive({:DOWN, ^monitor, :process, _, _}, 5_000)
      for name <- ["0", "1", "2", "control"], do: assert_receive({:peer_closed, ^name}, 5_000)
      requests = HTTPFixture.requests(fixture)
      assert Enum.count(requests, &(&1.method == "POST")) == 1
      refute Enum.any?(requests, &(&1.method == "DELETE"))
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "stderr progresses while stdout is stalled; exact aggregate limit succeeds over #{transport}",
         %{root: root} do
      {client, _, _} = fixture(root, unquote(transport), gate_stdout: true)
      {:ok, session} = Session.exec(client, "fixture", @body)
      assert_receive {:stdout_gate, peer}, 5_000

      sink = fn _ ->
        send(peer, :release_stdout)
        :ok
      end

      assert {:ok, result} = Session.collect(session, fn _ -> :ok end, sink, max_output_bytes: 7)
      assert result.stdout_bytes + result.stderr_bytes == 7
      assert_closed(session)
    end
  end

  for transport <- [:gen_tcp, :ssl] do
    test "normal close, malformed barrier and abrupt disconnect have distinct outcomes over #{transport}",
         %{
           root: root
         } do
      for {opts, expected} <- [
            {[end_frame: WebSocketFixture.frame(8, <<1000::16>>)], :ok},
            {[end_frame: WebSocketFixture.frame(1, "not a barrier")], :exec_output_protocol},
            {[abrupt: true], :exec_output_protocol}
          ] do
        {client, _, _} = fixture(root, unquote(transport), opts)
        {:ok, session} = Session.exec(client, "fixture", @body)

        if opts[:abrupt] do
          for name <- ["1", "2"] do
            assert_receive {:abrupt_peer, ^name, peer}, 5_000
            send(peer, :disconnect)
          end
        end

        result = Session.collect(session, fn _ -> :ok end, fn _ -> :ok end)

        if expected == :ok do
          assert {:ok, %{exit_status: 7}} = result
        else
          assert {:error, %Error{kind: kind, operation: url}} = result
          assert kind == expected or (opts[:abrupt] == true and kind == :channel_io)
          assert url == session.operation.url
        end

        assert_closed(session)
      end
    end
  end

  defp go_exec(root, credentials, mode, body, stdin \\ "") do
    input =
      Map.merge(credentials, %{
        Project: "p1",
        Member: "m1",
        Mode: mode,
        Stdin: Base.encode64(stdin),
        Body: body
      })

    file = Path.join(root, "input-#{System.unique_integer([:positive])}.json")
    File.write!(file, Jason.encode!(input))
    File.chmod!(file, 0o600)

    {out, 0} =
      System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "exec-fixture", @driver, file],
        stderr_to_stdout: true
      )

    Jason.decode!(out)
  end

  # Native submissions and per-channel upgrade targets (path plus decoded query).
  defp exchange(requests) do
    %{
      requests: requests,
      posts: for(%{method: "POST"} = request <- requests, do: WireComparison.request(request)),
      upgrades:
        requests
        |> Enum.filter(&(&1.headers["upgrade"] == "websocket"))
        |> Enum.map(&URI.parse(&1.target))
        |> Enum.map(&{&1.path, URI.decode_query(&1.query || "")})
        |> Enum.sort_by(fn {_, query} -> query["secret"] end)
    }
  end

  defp assert_exchanged(stdin) do
    assert_receive {:stdin, ^stdin}, 5_000
    assert_receive {:barrier, "0"}, 5_000
  end

  # Decoded as the server does into InstanceExecControl, so absent fields are zero values.
  defp controls do
    for _ <- 1..2 do
      assert_receive {:control, payload}, 5_000
      Map.merge(%{"command" => "", "args" => nil, "signal" => 0}, Jason.decode!(payload))
    end
  end

  defp send_chunk(parent, name, bytes),
    do:
      (
        send(parent, {name, bytes})
        :ok
      )

  defp assert_closed(session),
    do: assert(Enum.all?(session.channels, fn {_, c} -> not Process.alive?(c.pid) end))

  defp fixture(root, transport, opts \\ []) do
    parent = self()

    identity =
      if transport == :ssl,
        do: TLSIdentity.generate(root, "exec-#{System.unique_integer([:positive])}", "localhost")

    tls =
      if identity,
        do: [
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            verify: :verify_peer,
            fail_if_no_peer_cert: true,
            cacertfile: identity.cafile
          ]
        ],
        else: []

    handler = fn request ->
      cond do
        URI.parse(request.target).path == "/1.0" ->
          %{
            status: 200,
            body: %{
              type: "sync",
              metadata: %{
                api_version: "1.0",
                api_extensions: ["api_extensions" | Keyword.get(opts, :extensions, [])],
                environment: %{}
              }
            }
          }

        request.method == "POST" and is_integer(opts[:post_error]) ->
          native_error(opts[:post_error])

        request.method == "POST" ->
          request_gate(parent, opts[:post_gate])
          accepted(opts)

        request.headers["upgrade"] == "websocket" ->
          request_gate(parent, opts[:upgrade_gate])
          secret = URI.decode_query(URI.parse(request.target).query)["secret"]
          name = String.replace_prefix(secret, "secret-", "")

          if name == opts[:reject_upgrade],
            do: native_error(403),
            else: %{upgrade: fn t, s -> upgrade(t, s, request, name, parent, opts) end}

        true ->
          %{
            status: 200,
            body: %{
              type: "sync",
              metadata: %{
                id: "exec-id",
                status_code: Keyword.get(opts, :status, 200),
                err: if(opts[:status] == 400, do: "boom", else: ""),
                metadata: Keyword.get(opts, :metadata, %{"return" => 7})
              }
            }
          }
      end
    end

    fixture =
      start_supervised!(
        {HTTPFixture,
         [
           transport: transport,
           path: Path.join(root, "s-#{System.unique_integer([:positive])}"),
           handler: handler
         ] ++ tls},
        id: make_ref()
      )

    endpoint = HTTPFixture.endpoint(fixture)

    {connection, credentials} =
      if identity do
        {Connection.https!(endpoint.url,
           owner: :fixture,
           tls: [
             cacertfile: identity.cafile,
             certfile: identity.certfile,
             keyfile: identity.keyfile
           ]
         ),
         %{
           URL: endpoint.url,
           CA: File.read!(identity.cafile),
           Cert: File.read!(identity.certfile),
           Key: File.read!(identity.keyfile)
         }}
      else
        {Connection.unix!(endpoint.socket, owner: :fixture), %{Socket: endpoint.socket}}
      end

    client = %Incus{
      connection: %{connection | project: "p1", member: "m1"},
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: Keyword.get(opts, :extensions, [])}
    }

    {client, fixture, credentials}
  end

  defp upgrade(t, s, request, name, parent, opts) do
    if name == "0" and opts[:input_gate], do: setopts(t, s, recbuf: 4096)

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

    if name == "0" and opts[:input_gate] do
      send(parent, {:input_gate, self()})

      receive do
        :release_input -> :ok
      after
        20_000 -> raise "fixture input gate"
      end
    end

    if name in ["1", "2"], do: send_output(t, s, name, parent, opts)

    if opts[:abrupt] == true and name in ["1", "2"] do
      send(parent, {:abrupt_peer, name, self()})

      receive do
        :disconnect -> :ok
      after
        5_000 -> raise "fixture disconnect gate"
      end
    else
      receive_frames(t, s, name, parent, "", opts)
    end
  end

  defp accepted(opts) do
    fds =
      Keyword.get_lazy(opts, :fds, fn ->
        if(opts[:control],
          do: %{"0" => "0", "1" => "1", "2" => "2", "control" => "control"},
          else: %{"0" => "0", "1" => "1", "2" => "2"}
        )
      end)

    %{
      status: 202,
      body: %{
        type: "async",
        operation: "/1.0/operations/exec-id",
        metadata: %{
          id: "exec-id",
          status_code: 103,
          metadata: if(fds == :none, do: %{}, else: %{fds: fds})
        }
      }
    }
  end

  defp send_output(t, s, name, parent, opts) do
    if name == "1" and opts[:gate_stdout] do
      send(parent, {:stdout_gate, self()})

      receive do
        :release_stdout -> :ok
      after
        5_000 -> raise "fixture stdout gate"
      end
    end

    bytes = if name == "1", do: @stdout, else: @stderr
    output = if opts[:empty], do: "", else: WebSocketFixture.frame(2, bytes)

    barrier =
      if opts[:abrupt],
        do: "",
        else: Keyword.get(opts, :end_frame, WebSocketFixture.frame(1, ""))

    :ok = t.send(s, output <> barrier)
  end

  defp setopts(:gen_tcp, socket, opts), do: :inet.setopts(socket, opts)
  defp setopts(:ssl, socket, opts), do: :ssl.setopts(socket, opts)

  defp native_error(status),
    do: %{
      status: status,
      body: %{type: "error", error_code: status, error: "native #{status}", metadata: nil}
    }

  defp request_gate(parent, true) do
    send(parent, {:request_gate, self()})

    receive do
      :release_request -> :ok
    after
      10_000 -> raise "fixture request gate"
    end
  end

  defp request_gate(_, _), do: :ok

  defp receive_frames(t, s, name, parent, buffer, opts) do
    case :cow_ws.parse_header(buffer, %{}, :undefined) do
      :more ->
        receive_bytes(t, s, name, parent, buffer, 0, opts)

      {type, frag, rsv, length, mask, rest} ->
        if byte_size(rest) < length do
          receive_bytes(t, s, name, parent, buffer, length - byte_size(rest), opts)
        else
          {:ok, payload, _, rest} =
            :cow_ws.parse_payload(rest, mask, 0, 0, type, length, frag, %{}, rsv)

          case {type, name} do
            {:binary, _} -> send(parent, {:stdin, payload})
            {:text, "control"} -> send(parent, {:control, payload})
            {:text, _} -> send(parent, {:barrier, name})
            {:close, _} -> send(parent, {:peer_closed, name})
          end

          # An interactive PTY answers on channel 0 after its input barrier.
          if type == :text and name == "0" and opts[:interactive],
            do:
              :ok = t.send(s, WebSocketFixture.frame(2, @stdout) <> WebSocketFixture.frame(1, ""))

          if type != :close, do: receive_frames(t, s, name, parent, rest, opts)
        end
    end
  end

  defp receive_bytes(t, s, name, parent, buffer, length, opts) do
    case t.recv(s, length, Keyword.get(opts, :read_timeout, 5_000)) do
      {:ok, bytes} -> receive_frames(t, s, name, parent, buffer <> bytes, opts)
      {:error, :closed} -> send(parent, {:peer_closed, name})
      {:error, reason} -> send(parent, {:peer_error, name, reason})
    end
  end
end
