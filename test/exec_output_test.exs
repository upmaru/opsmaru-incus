defmodule Opsmaru.Incus.ExecOutputTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Operation, RequestContext, Server, Session}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture}
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
      requests = HTTPFixture.requests(fixture)
      posts = Enum.filter(requests, &(&1.method == "POST"))
      assert length(posts) == 2
      assert Enum.all?(posts, &(&1.target == "/1.0/instances/fixture/exec?project=p1&target=m1"))
      assert Enum.map(posts, &Jason.decode!(&1.body)) |> Enum.uniq() == [@body]
      refute Enum.any?(requests, &(&1.method == "DELETE"))
    end
  end

  test "limits and rejected/raising sinks retain acceptance and close all channels", %{root: root} do
    {client, fixture, _} = fixture(root, :gen_tcp)

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
    end

    assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 3
    refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
  end

  test "output barriers cannot substitute for final operation or valid exit metadata", %{
    root: root
  } do
    for {status, metadata, kind} <- [
          {103, %{"return" => 7}, :deadline},
          {400, %{}, :operation_failed},
          {200, %{}, :invalid_exec_status},
          {200, "malformed", :invalid_operation}
        ] do
      {client, _, _} = fixture(root, :gen_tcp, status: status, metadata: metadata)
      {:ok, session} = Session.exec(client, "fixture", @body)

      assert {:error, %Error{kind: ^kind, operation: url}} =
               Session.collect(session, fn _ -> :ok end, fn _ -> :ok end,
                 timeout: if(status == 103, do: 1_000, else: 5_000)
               )

      assert url == session.operation.url
      assert_closed(session)
    end
  end

  test "a stalled callback is bounded and killed, including exit trapping", %{root: root} do
    {client, _, _} = fixture(root, :gen_tcp)
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

  test "foreign creator and malformed options reject without touching channels", %{root: root} do
    {client, fixture, _} = fixture(root, :gen_tcp)
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

  test "host cancellation interrupts stalled sinks", %{root: root} do
    {client, _, _} = fixture(root, :gen_tcp)
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

  test "owner loss kills an exit-trapping sink and all channels without remote cancellation", %{
    root: root
  } do
    {client, fixture, _} = fixture(root, :gen_tcp, control: true)
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
      Enum.map([worker | Enum.map(session.channels, fn {_, c} -> c.pid end)], &Process.monitor/1)

    Process.exit(owner, :kill)
    for monitor <- monitors, do: assert_receive({:DOWN, ^monitor, :process, _, _}, 5_000)
    for name <- ["0", "1", "2", "control"], do: assert_receive({:peer_closed, ^name}, 5_000)
    requests = HTTPFixture.requests(fixture)
    assert Enum.count(requests, &(&1.method == "POST")) == 1
    refute Enum.any?(requests, &(&1.method == "DELETE"))
  end

  test "stderr progresses while stdout is stalled; exact aggregate limit succeeds", %{root: root} do
    {client, _, _} = fixture(root, :gen_tcp, gate_stdout: true)
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

  test "normal close, malformed barrier and abrupt disconnect have distinct outcomes", %{
    root: root
  } do
    for {opts, expected} <- [
          {[end_frame: WebSocketFixture.frame(8, <<1000::16>>)], :ok},
          {[end_frame: WebSocketFixture.frame(1, "not a barrier")], :exec_output_protocol},
          {[abrupt: true], :exec_output_protocol}
        ] do
      {client, _, _} = fixture(root, :gen_tcp, opts)
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
    identity = if transport == :ssl, do: TLSIdentity.generate(root, "exec", "localhost")

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
                api_extensions: ["api_extensions"],
                environment: %{}
              }
            }
          }

        request.method == "POST" ->
          %{
            status: 202,
            body: %{
              type: "async",
              operation: "/1.0/operations/exec-id",
              metadata: %{
                id: "exec-id",
                status_code: 103,
                metadata: %{
                  fds:
                    if(opts[:control],
                      do: %{"0" => "0", "1" => "1", "2" => "2", "control" => "control"},
                      else: %{"0" => "0", "1" => "1", "2" => "2"}
                    )
                }
              }
            }
          }

        request.headers["upgrade"] == "websocket" ->
          name = URI.decode_query(URI.parse(request.target).query)["secret"]
          %{upgrade: fn t, s -> upgrade(t, s, request, name, parent, opts) end}

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
      server: %Server{api_extensions: []}
    }

    {client, fixture, credentials}
  end

  defp upgrade(t, s, request, name, parent, opts) do
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

    if name in ["1", "2"] do
      if name == "1" and opts[:gate_stdout] do
        send(parent, {:stdout_gate, self()})

        receive do
          :release_stdout -> :ok
        after
          5_000 -> raise "fixture stdout gate"
        end
      end

      bytes = if name == "1", do: @stdout, else: @stderr

      :ok =
        t.send(
          s,
          WebSocketFixture.frame(2, bytes) <>
            if(opts[:abrupt],
              do: "",
              else: Keyword.get(opts, :end_frame, WebSocketFixture.frame(1, ""))
            )
        )
    end

    if opts[:abrupt] == true and name in ["1", "2"] do
      send(parent, {:abrupt_peer, name, self()})

      receive do
        :disconnect -> :ok
      after
        5_000 -> raise "fixture disconnect gate"
      end
    else
      receive_frames(t, s, name, parent, "")
    end
  end

  defp receive_frames(t, s, name, parent, buffer) do
    case :cow_ws.parse_header(buffer, %{}, :undefined) do
      :more ->
        case t.recv(s, 0, 5_000) do
          {:ok, bytes} -> receive_frames(t, s, name, parent, buffer <> bytes)
          _ -> send(parent, {:peer_closed, name})
        end

      {type, frag, rsv, length, mask, rest} ->
        if byte_size(rest) < length do
          {:ok, bytes} = t.recv(s, length - byte_size(rest), 5_000)
          receive_frames(t, s, name, parent, buffer <> bytes)
        else
          {:ok, payload, _, rest} =
            :cow_ws.parse_payload(rest, mask, 0, 0, type, length, frag, %{}, rsv)

          case type do
            :binary -> send(parent, {:stdin, payload})
            :text -> send(parent, {:barrier, name})
            :close -> send(parent, {:peer_closed, name})
          end

          if type != :close, do: receive_frames(t, s, name, parent, rest)
        end
    end
  end
end
