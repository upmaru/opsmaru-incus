defmodule Opsmaru.Incus.DynamicConsoleReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, DynamicConsole, Error, Server, WebSocket}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture, WireComparison}
  @driver Path.expand("../../.integration/incus-dynamic-console-driver", __DIR__)
  @extensions ["instances", "console", "console_vga_type", "console_force"]
  @payload <<255, 0, 128, 42>>

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./dynamicconsole"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-dyn-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    }
  end

  test "pinned helper opens one control and repeated console connections with native frames", %{
    root: root,
    context: context
  } do
    fixture = backend(root)

    result =
      oracle(%{
        socket: WebSocketFixture.path(fixture),
        body: %{width: 80, height: 24, force: true},
        payload: Base.encode64(@payload),
        project: "",
        target: ""
      })

    assert result["operation"]["id"] == "console-id"

    assert Enum.map(result["outputs"], &Base.decode64!/1) == [
             <<0, 255, 128>> <> @payload,
             <<0, 255, 128>> <> @payload
           ]

    native = WebSocketFixture.requests(fixture)
    client = client(fixture, context, false)

    assert {:ok, console} =
             DynamicConsole.open(
               client,
               "fixture",
               %{"width" => 80, "height" => 24, "force" => true},
               max_attachments: 1
             )

    assert :ok = DynamicConsole.resize(console, 80, 24)

    for _ <- 1..2 do
      assert {:ok, channel} = DynamicConsole.attach(console)
      assert {:ok, {:binary, <<0, 255, 128>>}} = WebSocket.recv(channel)
      assert :ok = WebSocket.send_frame(channel, {:binary, @payload})
      assert {:ok, {:binary, @payload}} = WebSocket.recv(channel)
      assert :ok = DynamicConsole.detach(console, channel)
      refute Process.alive?(channel.pid)
    end

    assert :ok = DynamicConsole.close(console)
    actual = WebSocketFixture.requests(fixture) |> Enum.drop(length(native))
    expected = Enum.reject(native, &(URI.parse(&1.target).path == "/1.0"))

    assert Enum.map(actual, &WireComparison.request/1) ==
             Enum.map(expected, &WireComparison.request/1)

    assert Enum.count(actual, &(&1.method == "POST")) == 1
    assert console.operation.url == "/1.0/operations/console-id"
    refute inspect(console) =~ "private-control"
  end

  test "attachment capacity, invalid control and owner isolation preserve accepted operation", %{
    root: root,
    context: context
  } do
    fixture = backend(root)

    assert {:ok, console} =
             DynamicConsole.open(client(fixture, context), "fixture", %{}, max_attachments: 1)

    assert {:ok, channel} = DynamicConsole.attach(console)

    assert {:error, %Error{kind: :capacity, operation: "/1.0/operations/console-id"}} =
             DynamicConsole.attach(console)

    assert {:error, %Error{kind: :invalid_console_arguments}} =
             DynamicConsole.control(console, [])

    assert {:error, %Error{kind: :invalid_console_arguments}} =
             DynamicConsole.control(console, %{unsupported: self()})

    assert {:error, %Error{kind: :owner_mismatch}} =
             Task.async(fn -> DynamicConsole.attach(console) end) |> Task.await()

    assert Process.alive?(console.pid)

    for request <- WebSocketFixture.requests(fixture) do
      assert URI.decode_query(URI.parse(request.target).query || "")
             |> Map.take(["project", "target"]) == %{"project" => "p +", "target" => "m +"}
    end

    assert :ok = DynamicConsole.detach(console, channel)
    assert :ok = DynamicConsole.close(console)
    assert Enum.count(WebSocketFixture.requests(fixture), &(&1.method == "POST")) == 1
  end

  for role <- ["private-control", "private-data"], kind <- [:overflow, :frame_limit] do
    test "#{role} #{kind} remains visible to the host after asynchronous channel failure", %{
      root: root,
      context: context
    } do
      role = unquote(role)
      kind = unquote(kind)
      parent = self()

      fixture =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(root, "channel-error"),
           handler: fn request ->
             if request.method == "POST" do
               accepted(%{"control" => "private-control", "0" => "private-data"})
             else
               %{
                 upgrade: fn adapter, socket ->
                   secret = URI.decode_query(URI.parse(request.target).query)["secret"]

                   accept =
                     Base.encode64(
                       :crypto.hash(
                         :sha,
                         request.headers["sec-websocket-key"] <>
                           "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                       )
                     )

                   :ok =
                     adapter.send(
                       socket,
                       "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
                     )

                   send(parent, {:peer, secret, self()})

                   receive do
                     {:emit, wire} ->
                       adapter.send(socket, wire)
                       adapter.recv(socket, 0, 1000)
                   after
                     3000 -> :ok
                   end
                 end
               }
             end
           end}
        )

      connection =
        Connection.unix!(
          HTTPFixture.endpoint(fixture).socket,
          [owner: :fixture] ++ error_budgets(kind)
        )

      client = %Incus{
        connection: connection,
        context: context,
        server: %Server{api_extensions: @extensions}
      }

      assert {:ok, console} = DynamicConsole.open(client, "fixture", %{})
      assert_receive {:peer, "private-control", control_peer}, 1000
      assert {:ok, channel} = DynamicConsole.attach(console)
      assert_receive {:peer, "private-data", data_peer}, 1000
      control = :sys.get_state(console.pid).control
      failed_channel = if role == "private-control", do: control, else: channel
      peer = if role == "private-control", do: control_peer, else: data_peer
      ref = failed_channel.ref
      pid = console.pid
      foreign_ref = make_ref()
      send(pid, {foreign_ref, :error, %Error{kind: :overflow}})
      refute_receive {:dynamic_console, ^pid, {^foreign_ref, :error, _}}, 30

      wire = error_wire(kind)

      monitor = Process.monitor(failed_channel.pid)
      send(peer, {:emit, wire})

      assert_receive {:dynamic_console, ^pid,
                      {^ref, :error,
                       %Error{
                         kind: ^kind,
                         operation: "/1.0/operations/console-id",
                         response: response
                       }}},
                     1000

      assert response.operation == console.operation.response
      assert response.error.kind == kind
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1000

      if role == "private-data" do
        assert Process.alive?(pid)
        assert :ok = DynamicConsole.close(console)
      else
        console_monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^console_monitor, :process, _, _}, 1000
      end

      assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 1
      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
    end
  end

  for closure <- [:close_frame, :disconnect] do
    test "remote control #{closure} promptly releases console attachments and retains accepted identity",
         %{root: root, context: context} do
      closure = unquote(closure)
      parent = self()

      fixture =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(root, "control-eof"),
           handler: fn request ->
             if request.method == "POST" do
               accepted(%{"control" => "private-control", "0" => "private-data"})
             else
               %{
                 upgrade: fn adapter, socket ->
                   secret = URI.decode_query(URI.parse(request.target).query)["secret"]

                   accept =
                     Base.encode64(
                       :crypto.hash(
                         :sha,
                         request.headers["sec-websocket-key"] <>
                           "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                       )
                     )

                   :ok =
                     adapter.send(
                       socket,
                       "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
                     )

                   send(parent, {:peer, secret, self()})

                   receive do
                     {:emit, :close_frame} ->
                       adapter.send(socket, WebSocketFixture.frame(8, <<1000::16>>))
                       adapter.recv(socket, 0, 1000)

                     {:emit, :disconnect} ->
                       :ok
                   after
                     3000 -> :ok
                   end
                 end
               }
             end
           end}
        )

      client = %Incus{
        connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
        context: context,
        server: %Server{api_extensions: @extensions}
      }

      assert {:ok, console} = DynamicConsole.open(client, "fixture", %{})
      assert_receive {:peer, "private-control", control_peer}, 1000
      assert {:ok, channel} = DynamicConsole.attach(console)
      assert_receive {:peer, "private-data", _}, 1000
      control = :sys.get_state(console.pid).control
      ref = control.ref
      pid = console.pid
      operation = console.operation
      cm = Process.monitor(pid)
      am = Process.monitor(channel.pid)
      send(control_peer, {:emit, closure})
      assert_receive {:dynamic_console, ^pid, {^ref, :eof, ^operation}}, 1000
      assert_receive {:DOWN, ^cm, :process, _, :normal}, 1000
      assert_receive {:DOWN, ^am, :process, _, :normal}, 1000
      assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 1
      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
    end
  end

  test "owner exit closes control and attachments without cancelling the backend", %{
    root: root,
    context: context
  } do
    fixture = backend(root)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, console} = DynamicConsole.open(client(fixture, context), "fixture", %{})
        {:ok, channel} = DynamicConsole.attach(console)
        send(parent, {:console, console, channel})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:console, console, channel}, 1000
    cm = Process.monitor(console.pid)
    am = Process.monitor(channel.pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^cm, :process, _, :normal}, 1000
    assert_receive {:DOWN, ^am, :process, _, :normal}, 1000
    refute Enum.any?(WebSocketFixture.requests(fixture), &(&1.method == "DELETE"))
  end

  test "the total console lifetime releases every channel and leaves native identity available",
       %{root: root, context: context} do
    fixture = backend(root)
    client = client(fixture, context)
    client = %{client | connection: %{client.connection | stream_timeout: 100}}
    assert {:ok, console} = DynamicConsole.open(client, "fixture", %{})
    assert {:ok, channel} = DynamicConsole.attach(console)
    cm = Process.monitor(console.pid)
    am = Process.monitor(channel.pid)
    assert_receive {:DOWN, ^cm, :process, _, :normal}, 1000
    assert_receive {:DOWN, ^am, :process, _, :normal}, 1000
    assert console.operation.response.operation == "/1.0/operations/console-id"
    assert Enum.count(WebSocketFixture.requests(fixture), &(&1.method == "POST")) == 1
    refute Enum.any?(WebSocketFixture.requests(fixture), &(&1.method == "DELETE"))
  end

  test "malformed accepted metadata and failed attachments never replay the mutation", %{
    root: root,
    context: context
  } do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "failed"),
         handler: fn req ->
           if req.method == "POST",
             do: accepted(%{"control" => "private-control", "0" => "private-data"}),
             else: %{status: 403, body: %{type: "error", error_code: 777, error: "rejected"}}
         end}
      )

    client = %Incus{
      connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
      context: context,
      server: %Server{api_extensions: @extensions}
    }

    assert {:error,
            %Error{
              kind: :stream_negotiation,
              operation: "/1.0/operations/console-id",
              response: response
            }} = DynamicConsole.open(client, "fixture", %{})

    assert response.operation.operation == "/1.0/operations/console-id"
    assert [%{method: "POST"}, %{method: "GET"}] = HTTPFixture.requests(fixture)
    fixture = backend(root, %{"control" => "private-control"})

    assert {:error,
            %Error{kind: :invalid_stream_metadata, operation: "/1.0/operations/console-id"}} =
             DynamicConsole.open(client(fixture, context), "fixture", %{})

    assert [%{method: "POST"}] = WebSocketFixture.requests(fixture)
  end

  test "a rejected later attachment retains control and operation without a second POST", %{
    root: root,
    context: context
  } do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "attach-rejected"),
         handler: fn request ->
           cond do
             request.method == "POST" ->
               accepted(%{"control" => "private-control", "0" => "private-data"})

             URI.decode_query(URI.parse(request.target).query || "")["secret"] ==
                 "private-control" ->
               accept =
                 Base.encode64(
                   :crypto.hash(
                     :sha,
                     request.headers["sec-websocket-key"] <>
                       "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                   )
                 )

               %{
                 wire_chunks: [
                   {0,
                    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"},
                   {1000, ""}
                 ]
               }

             true ->
               %{
                 status: 403,
                 body: %{type: "error", error_code: 777, error: "attachment-rejected"}
               }
           end
         end}
      )

    client = %Incus{
      connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
      context: context,
      server: %Server{api_extensions: @extensions}
    }

    assert {:ok, console} = DynamicConsole.open(client, "fixture", %{})

    assert {:error,
            %Error{
              kind: :stream_negotiation,
              operation: "/1.0/operations/console-id",
              response: response
            }} = DynamicConsole.attach(console)

    assert response.operation.operation == "/1.0/operations/console-id"
    assert response.error.error_code == 777
    assert Process.alive?(console.pid)
    assert :ok = DynamicConsole.close(console)
    assert [%{method: "POST"}, %{method: "GET"}, %{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  test "invalid options, unsupported extension and readiness fail before any mutation", %{
    root: root,
    context: context
  } do
    client = %Incus{
      connection: Connection.unix!(Path.join(root, "absent"), owner: :fixture),
      context: context,
      server: %Server{api_extensions: []}
    }

    assert {:error, %Error{kind: :invalid_console_arguments}} =
             DynamicConsole.open(client, "fixture", %{}, max_attachments: 0)

    assert {:error, %Error{kind: :unsupported_extension}} =
             DynamicConsole.open(client, "fixture", %{})

    client = %{client | context: %{context | ready?: fn -> false end}}
    assert {:error, %Error{kind: :host_not_ready}} = DynamicConsole.open(client, "fixture", %{})
  end

  test "verified HTTPS dynamic console retains coalesced binary frames and independent attachments",
       %{root: root, context: context} do
    identity = TLSIdentity.generate(root, "dynamic", "localhost")

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: identity.certfile,
         keyfile: identity.keyfile,
         handler: fn request ->
           if request.method == "POST" do
             accepted(%{"control" => "private-control", "0" => "private-data"})
           else
             %{
               upgrade: fn adapter, socket ->
                 accept =
                   Base.encode64(
                     :crypto.hash(
                       :sha,
                       request.headers["sec-websocket-key"] <>
                         "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                     )
                   )

                 adapter.send(
                   socket,
                   "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n" <>
                     WebSocketFixture.frame(2, <<0, 255, 128>>)
                 )

                 receive_frame(adapter, socket)
               end
             }
           end
         end}
      )

    connection =
      Connection.https!(HTTPFixture.endpoint(fixture).url,
        owner: :fixture,
        tls: [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
      )

    client = %Incus{
      connection: connection,
      context: context,
      server: %Server{api_extensions: @extensions}
    }

    assert {:ok, console} = DynamicConsole.open(client, "fixture", %{})

    for _ <- 1..2 do
      assert {:ok, channel} = DynamicConsole.attach(console)
      assert {:ok, {:binary, <<0, 255, 128>>}} = WebSocket.recv(channel)
      assert :ok = WebSocket.send_frame(channel, {:binary, @payload})
      assert {:ok, {:binary, @payload}} = WebSocket.recv(channel)
      DynamicConsole.detach(console, channel)
    end

    DynamicConsole.close(console)
    assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 1
  end

  defp error_budgets(:overflow), do: [queue_limit: 1, max_response_bytes: 1024]

  defp error_budgets(:frame_limit),
    do: [queue_limit: 1, max_response_bytes: 1024, max_stream_bytes: 1024]

  defp error_wire(:overflow), do: WebSocketFixture.frame(2, "a") <> WebSocketFixture.frame(2, "b")
  defp error_wire(:frame_limit), do: WebSocketFixture.frame(2, :binary.copy(<<0>>, 1536))

  defp receive_frame(adapter, socket) do
    case adapter.recv(socket, 2, 3000) do
      {:ok, <<_::4, opcode::4, 1::1, length::7>>} when length <= 125 ->
        {:ok, <<mask::binary-size(4), data::binary-size(length)>>} =
          adapter.recv(socket, 4 + length, 3000)

        if opcode != 8 do
          payload =
            data
            |> :binary.bin_to_list()
            |> Enum.with_index()
            |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
            |> :binary.list_to_bin()

          adapter.send(socket, WebSocketFixture.frame(opcode, payload))
          receive_frame(adapter, socket)
        end

      _ ->
        :ok
    end
  end

  defp accepted(fds),
    do: %{
      status: 202,
      body: %{
        type: "async",
        operation: "/1.0/operations/console-id",
        metadata: %{id: "console-id", status_code: 103, metadata: %{fds: fds}}
      }
    }

  defp backend(root, fds \\ %{"control" => "private-control", "0" => "private-data"}),
    do:
      start_supervised!(
        {WebSocketFixture,
         path: Path.join(root, "s-#{System.unique_integer([:positive])}"),
         api_extensions: @extensions,
         http_handler: fn _ -> accepted(fds) end},
        id: make_ref()
      )

  defp client(fixture, context, selected \\ true),
    do: %Incus{
      connection:
        Connection.unix!(WebSocketFixture.path(fixture),
          owner: :fixture,
          project: if(selected, do: "p +"),
          member: if(selected, do: "m +")
        ),
      context: context,
      server: %Server{api_extensions: @extensions}
    }

  defp oracle(input) do
    port =
      Port.open({:spawn_executable, @driver}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} when byte_size(data) + byte_size(bytes) <= 1_048_576 ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)

      {^port, {:exit_status, status}} ->
        flunk("native console oracle failed #{status}: #{data}")
    after
      6000 ->
        Port.close(port)
        flunk("native console oracle deadline")
    end
  end
end
