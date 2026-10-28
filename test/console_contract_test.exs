defmodule Opsmaru.Incus.ConsoleContractTest do
  @moduledoc """
  S02 console certification against the unchanged pinned `ConsoleInstance` and
  `ConsoleInstanceDynamic`. Each backend records every request and every client
  frame per WebSocket, so requests, channel order, control and data frames, write
  barriers and the detach close frame are compared on Unix and mutual HTTPS.
  """
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, DynamicConsole, Error, Server, Session, WebSocket}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture}

  @driver Path.expand("../.integration/console-driver", __DIR__)
  @extensions ["instances", "console", "console_vga_type", "console_force"]
  @fds %{"control" => "private-control", "0" => "private-data"}
  @greeting <<0, 255, 128>>
  @payload <<255, 0, 128, 42>>
  @attachments 2

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./console"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-s02-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} static and dynamic consoles agree with the pinned helpers", %{root: root} do
      identity = identity(root, unquote(transport))

      for mode <- [:static, :dynamic],
          body <- [%{}, %{"width" => 80, "height" => 24}, %{"type" => "vga", "force" => true}] do
        native = backend(root, identity)
        result = oracle(native, mode, body)
        assert result["operation"]["id"] == "console-id"
        attachments = if mode == :static, do: 1, else: @attachments
        assert decode_outputs(result) == List.duplicate(@greeting <> @payload, attachments)

        ours = backend(root, identity)
        drive(mode, client(ours, identity), body)
        await_frames(ours, attachments, true)

        assert requests(ours) == requests(native), "#{mode} #{inspect(body)}"
        assert [{"control", _} | data] = frames(ours)
        assert length(data) == attachments
        assert comparable(frames(ours)) == comparable(frames(native))

        # Explicit detach ends each data channel with a bare close frame, where the
        # pinned mirror closes the socket after the echoed barrier.
        assert Enum.all?(data, fn {"data", frames} -> List.last(frames) == {8, ""} end)
        assert Enum.count(requests(ours), &(&1["method"] == "POST")) == 1
      end
    end
  end

  for transport <- [:unix, :https] do
    test "#{transport} extension guards, native rejection and missing control match the pinned helpers",
         %{root: root} do
      identity = identity(root, unquote(transport))

      guards = [
        {@extensions -- ["console"], %{}},
        {@extensions -- ["console_vga_type"], %{"type" => "vga"}},
        {@extensions -- ["console_force"], %{"force" => true}}
      ]

      for mode <- [:static, :dynamic], {extensions, body} <- guards do
        native = backend(root, identity, extensions: extensions)
        assert %{"error" => message} = oracle(native, mode, body)
        assert message =~ "The server is missing the required"
        ours = backend(root, identity, extensions: extensions)

        assert {:error, %Error{kind: :unsupported_extension}} =
                 open(mode, client(ours, identity, extensions), body)

        assert requests(native) == [] and requests(ours) == []
      end

      for mode <- [:static, :dynamic], code <- [400, 403, 404] do
        reply = %{
          status: code,
          body: %{type: "error", error_code: code, error: "rejected #{code}"}
        }

        native = backend(root, identity, reply: reply)
        assert %{"error" => message} = oracle(native, mode, %{})
        ours = backend(root, identity, reply: reply)

        assert {:error, %Error{kind: :native, http_status: ^code, message: ^message}} =
                 open(mode, client(ours, identity), %{})

        assert requests(ours) == requests(native)
        assert [%{"method" => "POST"}] = requests(ours)
      end

      for mode <- [:static, :dynamic] do
        reply = accepted(%{"0" => "private-data"})
        native = backend(root, identity, reply: reply)

        assert %{"error" => "Did not receive a file descriptor for the control channel"} =
                 oracle(native, mode, %{})

        ours = backend(root, identity, reply: reply)

        assert {:error,
                %Error{kind: :invalid_stream_metadata, operation: "/1.0/operations/console-id"}} =
                 open(mode, client(ours, identity), %{})

        assert requests(ours) == requests(native)
        assert [%{"method" => "POST"}] = requests(ours)
      end
    end
  end

  test "malformed channel secrets fail closed with the accepted operation and open no channel",
       %{root: root} do
    for fds <- [
          %{"control" => "private-control"},
          %{"control" => "private-control", "0" => ""},
          %{"control" => "private-control", "0" => 7},
          %{"control" => "", "0" => "private-data"},
          "fds"
        ] do
      fixture = backend(root, nil, reply: accepted(fds))

      assert {:error,
              %Error{
                kind: :invalid_stream_metadata,
                operation: "/1.0/operations/console-id",
                response: response
              }} = Session.console(client(fixture, nil), "fixture", %{})

      assert response.operation == "/1.0/operations/console-id"
      assert [%{"method" => "POST"}] = requests(fixture)
      assert frames(fixture) == []
    end

    # Other accepted channels are ignored, as in the pinned helper.
    fixture = backend(root, nil, reply: accepted(Map.put(@fds, "1", "private-extra")))
    assert {:ok, session} = Session.console(client(fixture, nil), "fixture", %{})
    assert Map.keys(session.channels) == ["0", "control"]
    assert :ok = Session.close(session)

    assert Enum.map(websockets(fixture), & &1["query"]["secret"]) ==
             Map.values(@fds) |> Enum.sort()
  end

  test "lost, malformed and rejected-channel replies are uncertain or retained and never replayed",
       %{root: root} do
    for mode <- [:static, :dynamic], reply <- [%{raw: ""}, %{status: 200, body: "malformed"}] do
      fixture = backend(root, nil, reply: reply)

      assert {:error, %Error{kind: :uncertain}} = open(mode, client(fixture, nil), %{})
      assert [%{"method" => "POST"}] = requests(fixture)
    end

    # A rejected data channel detaches the control channel already opened, which the
    # pinned helper leaves open, and keeps the accepted operation for reconciliation.
    fixture = backend(root, nil, reject: "private-data")

    assert {:error,
            %Error{
              kind: :stream_negotiation,
              operation: "/1.0/operations/console-id",
              response: response
            }} = Session.console(client(fixture, nil), "fixture", %{})

    assert response.operation.operation == "/1.0/operations/console-id"
    assert response.error.http_status == 403
    assert ["private-control", "private-data"] = websocket_secrets(fixture)

    await(fn ->
      frames(fixture) == [{"control", [{8, <<1000::16, "Detaching from console">>}]}]
    end)

    assert Enum.count(requests(fixture), &(&1["method"] == "POST")) == 1
  end

  test "invalid bodies and options fail before any request", %{root: root} do
    fixture = backend(root, nil)
    client = client(fixture, nil)

    for mode <- [:static, :dynamic],
        body <- [%{"width" => "80"}, %{"force" => "yes"}, %{"type" => 1}, [1], "console"] do
      assert {:error, %Error{kind: :invalid_console_arguments}} = open(mode, client, body)
    end

    assert {:error, %Error{kind: :invalid_console_arguments}} =
             DynamicConsole.open(client, "fixture", %{}, max_attachments: 0)

    assert requests(fixture) == []
  end

  defp drive(:static, client, body) do
    assert {:ok, session} = Session.console(client, "fixture", body)
    assert :ok = Session.resize(session, 80, 24)
    assert {:ok, {:binary, @greeting}} = Session.output(session)
    assert :ok = Session.input(session, @payload)
    assert :ok = Session.close_input(session)
    assert {:ok, {:binary, @payload}} = Session.output(session)
    assert {:ok, {:text, ""}} = Session.output(session)
    assert :ok = Session.close(session)
  end

  defp drive(:dynamic, client, body) do
    assert {:ok, console} = DynamicConsole.open(client, "fixture", body)
    assert :ok = DynamicConsole.resize(console, 80, 24)

    for _ <- 1..@attachments do
      assert {:ok, channel} = DynamicConsole.attach(console)
      assert {:ok, {:binary, @greeting}} = WebSocket.recv(channel)
      assert :ok = WebSocket.send_frame(channel, {:binary, @payload})
      assert :ok = WebSocket.send_frame(channel, {:text, ""})
      assert {:ok, {:binary, @payload}} = WebSocket.recv(channel)
      assert {:ok, {:text, ""}} = WebSocket.recv(channel)
      assert :ok = DynamicConsole.detach(console, channel)
    end

    assert :ok = DynamicConsole.close(console)
  end

  defp open(:static, client, body), do: Session.console(client, "fixture", body)

  defp open(:dynamic, client, body) do
    with {:ok, console} <- DynamicConsole.open(client, "fixture", body) do
      DynamicConsole.close(console)
      {:ok, console}
    end
  end

  # Requests other than discovery, with JSON bodies stripped of the zero values
  # the pinned client always marshals.
  defp requests(fixture) do
    fixture.server
    |> HTTPFixture.requests()
    |> Enum.reject(&(URI.parse(&1.target).path == "/1.0"))
    |> Enum.map(fn request ->
      uri = URI.parse(request.target)

      %{
        "method" => request.method,
        "path" => uri.path,
        "query" => URI.decode_query(uri.query || ""),
        "body" => if(request.body == "", do: nil, else: zero(Jason.decode!(request.body)))
      }
    end)
  end

  defp websockets(fixture), do: Enum.filter(requests(fixture), &(&1["method"] == "GET"))
  defp websocket_secrets(fixture), do: Enum.map(websockets(fixture), & &1["query"]["secret"])

  defp zero(body) when is_map(body),
    do: body |> Enum.reject(fn {_, value} -> value in [0, false, "", nil] end) |> Map.new()

  defp zero(body), do: body

  defp frames(fixture), do: Agent.get(fixture.frames, &Enum.reverse/1) |> Enum.map(&ordered/1)

  defp ordered({role, frames}), do: {role, Enum.reverse(frames)}

  # Control text is compared as JSON (the pinned marshal and ours order keys alike,
  # but only the decoded command is native); data close frames are compared apart.
  defp comparable(frames) do
    Enum.map(frames, fn
      {"control", frames} ->
        {"control",
         Enum.map(frames, fn
           {1, text} -> {1, Jason.decode!(text)}
           frame -> frame
         end)}

      {"data", frames} ->
        {"data", Enum.reject(frames, &match?({8, _}, &1))}
    end)
  end

  # The control channel has its detach close frame, and every data channel its
  # payload and barrier. Our explicit detach also closes each data channel with a
  # frame; the pinned mirror only closes the socket, so its data close is not awaited.
  defp await_frames(fixture, attachments, data_close? \\ false) do
    await(fn ->
      case frames(fixture) do
        [{"control", control} | data] ->
          List.last(control) == {8, <<1000::16, "Detaching from console">>} and
            length(data) == attachments and
            Enum.all?(data, fn {"data", frames} ->
              {1, ""} in frames and (not data_close? or List.last(frames) == {8, ""})
            end)

        _ ->
          false
      end
    end)
  end

  defp await(check, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("console frames deadline")

      true ->
        Process.sleep(10)
        await(check, deadline)
    end
  end

  defp decode_outputs(result), do: Enum.map(result["outputs"], &Base.decode64!/1)

  defp accepted(fds),
    do: %{
      status: 202,
      body: %{
        type: "async",
        operation: "/1.0/operations/console-id",
        metadata: %{id: "console-id", status_code: 103, metadata: %{fds: fds}}
      }
    }

  defp backend(root, identity, opts \\ []) do
    {:ok, frames} = Agent.start_link(fn -> [] end)
    extensions = Keyword.get(opts, :extensions, @extensions)
    reply = Keyword.get(opts, :reply, accepted(@fds))
    reject = Keyword.get(opts, :reject)

    handler = fn request ->
      uri = URI.parse(request.target)
      secret = URI.decode_query(uri.query || "")["secret"]

      cond do
        uri.path == "/1.0" ->
          %{
            status: 200,
            body: %{
              type: "sync",
              metadata: %{api_version: "1.0", api_extensions: extensions, environment: %{}}
            }
          }

        request.method == "POST" ->
          reply

        secret == reject ->
          %{status: 403, body: %{type: "error", error_code: 403, error: "rejected channel"}}

        true ->
          %{upgrade: &serve(frames, request, secret, &1, &2)}
      end
    end

    options =
      if identity,
        do: [
          transport: :ssl,
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            cacertfile: identity.cafile,
            verify: :verify_peer,
            fail_if_no_peer_cert: true
          ]
        ],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "c-#{System.unique_integer([:positive])}")
        ]

    server = start_supervised!({HTTPFixture, options ++ [handler: handler]}, id: make_ref())

    %{
      server: server,
      frames: frames,
      endpoint: HTTPFixture.endpoint(server),
      identity: identity,
      root: root
    }
  end

  # Native 101 with the greeting frame, then every client frame is recorded and
  # every non-close frame echoed, until a close frame or socket closure.
  defp serve(frames, request, secret, adapter, socket) do
    role = if secret == @fds["control"], do: "control", else: "data"
    index = Agent.get_and_update(frames, &{length(&1), [{role, []} | &1]})

    accept =
      Base.encode64(
        :crypto.hash(
          :sha,
          request.headers["sec-websocket-key"] <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        )
      )

    :ok =
      adapter.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n" <>
          WebSocketFixture.frame(2, @greeting)
      )

    record(frames, index, adapter, socket)
  end

  defp record(frames, index, adapter, socket) do
    with {:ok, opcode, payload} <- receive_frame(adapter, socket) do
      Agent.update(frames, fn all ->
        List.update_at(all, length(all) - 1 - index, fn {role, seen} ->
          {role, [{opcode, payload} | seen]}
        end)
      end)

      if opcode != 8 do
        adapter.send(socket, WebSocketFixture.frame(opcode, payload))
        record(frames, index, adapter, socket)
      end
    end
  end

  defp receive_frame(adapter, socket) do
    with {:ok, <<_::4, opcode::4, 1::1, length::7>>} <- adapter.recv(socket, 2, 5_000),
         {:ok, length} <- extended(adapter, socket, length),
         {:ok, <<mask::binary-size(4), data::binary-size(length)>>} <-
           adapter.recv(socket, 4 + length, 5_000) do
      payload =
        data
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
        |> :binary.list_to_bin()

      {:ok, opcode, payload}
    end
  end

  defp extended(_adapter, _socket, 0), do: {:ok, 0}

  defp extended(adapter, socket, 126) do
    with {:ok, <<length::16>>} <- adapter.recv(socket, 2, 5_000), do: {:ok, length}
  end

  defp extended(_adapter, _socket, length) when length < 126, do: {:ok, length}

  defp client(fixture, identity, extensions \\ @extensions) do
    connection =
      if identity,
        do:
          Connection.https!(fixture.endpoint.url,
            owner: :fixture,
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          ),
        else: Connection.unix!(fixture.endpoint.socket, owner: :fixture)

    %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: extensions}
    }
  end

  defp identity(_root, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "s02-#{System.unique_integer([:positive])}", "localhost")

  defp oracle(fixture, mode, body) do
    endpoint =
      case fixture.endpoint do
        %{socket: socket} ->
          %{socket: socket}

        %{url: url} ->
          %{
            url: url,
            server_cert: File.read!(fixture.identity.certfile),
            client_cert: File.read!(fixture.identity.certfile),
            client_key: File.read!(fixture.identity.keyfile)
          }
      end

    input =
      Map.merge(endpoint, %{
        mode: Atom.to_string(mode),
        body: body,
        payload: Base.encode64(@payload),
        attachments: @attachments,
        expect: byte_size(@greeting <> @payload),
        temp: fixture.root
      })

    port =
      Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])

    Port.command(port, Jason.encode!(input) <> "\n")
    result = Jason.decode!(line(port, ""))

    # Hold the pinned connections open until the detach frames are recorded.
    if result["operation"], do: await_frames(fixture, length(result["outputs"]))
    Port.close(port)
    result
  end

  defp line(port, data) do
    receive do
      {^port, {:data, bytes}} when byte_size(data) + byte_size(bytes) <= 1_048_576 ->
        data = data <> bytes
        if String.ends_with?(data, "\n"), do: data, else: line(port, data)

      {^port, {:exit_status, status}} ->
        flunk("native console oracle exited #{status}: #{data}")
    after
      8_000 ->
        Port.close(port)
        flunk("native console oracle deadline")
    end
  end
end
