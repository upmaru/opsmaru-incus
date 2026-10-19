defmodule Opsmaru.Incus.EventContractTest do
  @moduledoc "B03/S03 event subscription selectors, native rejection and Event fields."
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, EventListener, Events, Model, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture, WireComparison}
  @driver Path.expand("../.integration/event-selectors-driver", __DIR__)

  @populated %{
    "type" => "lifecycle",
    "timestamp" => "2026-10-11T12:00:00.123456789Z",
    "metadata" => %{"action" => "instance-started", "source" => "/1.0/instances/c1"},
    "location" => "member/a",
    "project" => "fixture scope"
  }
  @minimal %{"type" => "logging", "timestamp" => "2026-10-11T12:00:00Z", "metadata" => %{}}

  # Pinned client action => equivalent explicit subscription options.
  @selectors [
    {"GetEvents", [], []},
    {"GetEventsByType", ["logging", "lifecycle"], [types: ["logging", "lifecycle"]]},
    {"GetEventsAllProjects", [], [all_projects: true]},
    {"GetEventsAllProjectsByType", ["operation", "network-acl"],
     [all_projects: true, types: ["operation", "network-acl"]]}
  ]

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./eventselectors"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-econtract-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} event selector upgrade targets and Event fields agree with the pinned client",
         %{root: root} do
      tls = identity(root, unquote(transport))

      for {action, types, opts} <- @selectors, event <- [@populated, @minimal] do
        parent = self()
        tag = make_ref()
        native = backend(root, tls, &streaming(parent, tag, event, &1))
        expected = oracle(native, tls, %{action: action, types: types})
        assert_receive {^tag, :peer_closed}, 5_000
        refute expected["error"]

        fixture = backend(root, tls, &streaming(parent, tag, event, &1))
        client = client(fixture, tls)
        assert {:ok, listener} = EventListener.open(client, opts)
        assert {:ok, _} = EventListener.add_handler(listener, [], &send(parent, {tag, &1}))
        assert_receive {^tag, %Model{type: "Event", data: data}}, 5_000
        assert data == expected["event"]
        assert :ok = EventListener.disconnect(listener)
        assert_receive {^tag, :peer_closed}, 5_000

        assert WireComparison.request(events_request(native)) ==
                 WireComparison.request(events_request(fixture))

        assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
        query = URI.decode_query(URI.parse(events_request(fixture).target).query)
        assert query["target"] == "member/a"
        assert Map.has_key?(query, "project") == not Keyword.has_key?(opts, :all_projects)
        if types != [], do: assert(query["type"] == Enum.join(types, ","))
      end
    end

    test "#{transport} native event upgrade rejection agrees with the pinned client", %{
      root: root
    } do
      tls = identity(root, unquote(transport))

      for {action, types, opts, status, message} <- [
            {"GetEvents", [], [], 403, "not authorized"},
            {"GetEventsByType", ["bogus"], [types: ["bogus"]], 400,
             ~s("bogus" isn't a supported event type)},
            {"GetEvents", [], [], 404, "Project not found"}
          ] do
        reply = %{
          status: status,
          body: %{type: "error", error_code: status, error: message}
        }

        native = backend(root, tls, fn _ -> reply end)
        expected = oracle(native, tls, %{action: action, types: types})
        # The pinned client prefixes its handshake failure; the native message is retained.
        assert String.starts_with?(expected["error"], "websocket: bad handshake\n#{message}")
        assert expected["error_status"] == status

        fixture = backend(root, tls, fn _ -> reply end)
        client = client(fixture, tls)

        assert {:error,
                %Error{
                  kind: :native,
                  http_status: ^status,
                  error_code: ^status,
                  message: ^message
                }} = Events.subscribe(client, opts)

        assert {:error, %Error{kind: :native, http_status: ^status}} =
                 EventListener.open(client, opts)

        assert WireComparison.request(events_request(native)) ==
                 WireComparison.request(events_request(fixture))

        # One upgrade per subscription attempt; a rejection is never retried.
        assert [%{method: "GET"}, %{method: "GET"}] = HTTPFixture.requests(fixture)
      end
    end
  end

  test "subscription options are validated before any upgrade", %{root: root} do
    fixture = backend(root, nil, fn _ -> flunk("unexpected request") end)
    client = client(fixture, nil)

    for types <- [
          "logging",
          [""],
          [:logging],
          [String.duplicate("x", 129)],
          List.duplicate("logging", 33)
        ] do
      assert {:error, %Error{kind: :invalid_event_types}} = Events.subscribe(client, types: types)
    end

    assert HTTPFixture.requests(fixture) == []
  end

  # Native events stream until the client ends the subscription; resending keeps a
  # handler registered after the upgrade from missing the first event.
  defp streaming(parent, tag, event, request) do
    %{
      upgrade: fn transport, socket ->
        :ok = transport.send(socket, accept(request))
        frame = WebSocketFixture.frame(1, Jason.encode!(event))
        send(parent, {tag, peer(transport, socket, frame)})
      end
    }
  end

  defp peer(transport, socket, frame) do
    case transport.send(socket, frame) do
      :ok ->
        case transport.recv(socket, 0, 25) do
          {:error, :timeout} -> peer(transport, socket, frame)
          {:ok, _} -> drain(transport, socket)
          {:error, _} -> :peer_closed
        end

      {:error, _} ->
        :peer_closed
    end
  end

  defp drain(transport, socket) do
    case transport.recv(socket, 0, 5_000) do
      {:ok, _} -> drain(transport, socket)
      {:error, :closed} -> :peer_closed
      {:error, reason} -> {:peer_open, reason}
    end
  end

  defp accept(request) do
    key =
      Base.encode64(
        :crypto.hash(
          :sha,
          request.headers["sec-websocket-key"] <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        )
      )

    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{key}\r\n\r\n"
  end

  defp events_request(fixture),
    do:
      fixture
      |> HTTPFixture.requests()
      |> Enum.filter(&(URI.parse(&1.target).path == "/1.0/events"))
      |> List.last()

  defp oracle(fixture, tls, input) do
    input =
      Map.merge(input, %{project: "fixture scope", target: "member/a"})
      |> Map.merge(native_connection(fixture, tls))

    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} -> collect(port, data <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(data)
      {^port, {:exit_status, status}} -> flunk("event selector oracle failed #{status}: #{data}")
    after
      10_000 ->
        Port.close(port)
        flunk("event selector oracle deadline")
    end
  end

  defp identity(_root, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "econtract-#{System.unique_integer([:positive])}", "localhost")

  defp backend(root, tls, handler) do
    options =
      if tls,
        do: [
          transport: :ssl,
          certfile: tls.certfile,
          keyfile: tls.keyfile,
          peer_options: [cacertfile: tls.cafile, verify: :verify_peer, fail_if_no_peer_cert: true]
        ],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "s#{System.unique_integer([:positive])}")
        ]

    start_supervised!(
      {HTTPFixture,
       options ++
         [
           handler: fn request ->
             if URI.parse(request.target).path == "/1.0" do
               %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{api_version: "1.0", api_extensions: [], environment: %{}}
                 }
               }
             else
               handler.(request)
             end
           end
         ]},
      id: make_ref()
    )
  end

  defp client(fixture, tls) do
    endpoint = HTTPFixture.endpoint(fixture)
    options = [owner: :fixture, project: "fixture scope", member: "member/a", timeout: 5_000]

    connection =
      if tls,
        do:
          Connection.https!(
            endpoint.url,
            options ++
              [tls: [cacertfile: tls.cafile, certfile: tls.certfile, keyfile: tls.keyfile]]
          ),
        else: Connection.unix!(endpoint.socket, options)

    %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: []}
    }
  end

  defp native_connection(fixture, nil), do: %{socket: HTTPFixture.endpoint(fixture).socket}

  defp native_connection(fixture, tls),
    do: %{
      url: HTTPFixture.endpoint(fixture).url,
      server_cert: File.read!(tls.certfile),
      tls_ca: File.read!(tls.cafile),
      client_cert: File.read!(tls.certfile),
      client_key: File.read!(tls.keyfile)
    }
end
