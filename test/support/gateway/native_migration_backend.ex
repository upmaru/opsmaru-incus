defmodule Opsmaru.TestSupport.NativeMigrationBackend do
  @moduledoc "Database-free migration negotiation/channel oracle, never a workload backend."
  alias Opsmaru.Incus.Connection
  alias Opsmaru.TestSupport.{HTTPFixture, WebSocketFixture}
  @driver Path.expand("../../../.integration/gateway-migration-driver", __DIR__)
  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @channels ~w(control fs)

  def extensions, do: ~w(instances container_push container_push_target)
  def driver, do: @driver

  def build! do
    File.mkdir_p!(Path.dirname(@driver))

    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./gatewaymigration"],
        cd: Path.expand("../../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    if status != 0, do: raise(output)
    :ok
  end

  def start(context, name, opts \\ []) do
    log =
      Keyword.get_lazy(opts, :log, fn ->
        ExUnit.Callbacks.start_supervised!({Agent, fn -> [] end}, id: make_ref())
      end)

    transport = Keyword.get(opts, :transport, :unix)

    certificate =
      case transport do
        :unix -> "guest certificate"
        {:https, server, _client} -> File.read!(server.certfile)
      end

    state = %{root: context.root, name: name, log: log, opts: opts, certificate: certificate}

    options =
      case transport do
        :unix ->
          [
            transport: :gen_tcp,
            path: Path.join(context.root, "mig-#{name}-#{System.unique_integer([:positive])}")
          ]

        {:https, server, client} ->
          [
            transport: :ssl,
            certfile: server.certfile,
            keyfile: server.keyfile,
            peer_options: [
              verify: :verify_peer,
              fail_if_no_peer_cert: false,
              cacertfile: client.cafile
            ]
          ]
      end

    fixture =
      ExUnit.Callbacks.start_supervised!(
        {HTTPFixture, options ++ [handler: &respond(state, &1, URI.parse(&1.target).path)]},
        id: make_ref()
      )

    endpoint = HTTPFixture.endpoint(fixture)

    connection =
      case transport do
        :unix ->
          Connection.unix!(endpoint.socket, owner: :fixture)

        {:https, server, client} ->
          Connection.https!(endpoint.url,
            owner: :fixture,
            tls: [cacertfile: server.cafile, certfile: client.certfile, keyfile: client.keyfile]
          )
      end

    %{fixture: fixture, connection: connection, name: name, log: log, endpoint: endpoint}
  end

  def events(side), do: Agent.get(side.log, &Enum.reverse/1)
  def requests(side), do: HTTPFixture.requests(side.fixture)

  def model(:instance),
    do: %{
      "name" => "source",
      "type" => "container",
      "status" => "Stopped",
      "status_code" => 102,
      "architecture" => "aarch64",
      "config" => %{},
      "devices" => %{},
      "profiles" => [],
      "ephemeral" => false
    }

  def model(:snapshot),
    do: %{
      "name" => "source/snapshot",
      "stateful" => false,
      "architecture" => "aarch64",
      "config" => %{},
      "devices" => %{},
      "profiles" => [],
      "ephemeral" => false
    }

  def run(root, input) do
    path = Path.join(root, "migration-input-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(input))
    File.chmod!(path, 0o600)

    try do
      {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
      if status != 0, do: raise(output)
      Jason.decode!(output)
    after
      File.rm(path)
    end
  end

  defp respond(side, request, path) do
    # Match pinned incusd instanceGet/instanceDelete: a snapshot name sent to
    # the root instance route is invalid, even when the slash is percent encoded.
    # In particular, do not make the upstream CLI snapshot-move delete bug pass.
    invalid =
      case String.split(path, "/") do
        ["", "1.0", "instances", name] -> String.contains?(URI.decode(name), "/")
        _ -> false
      end

    if invalid do
      %{status: 400, body: %{type: "error", error: "Invalid instance name", error_code: 400}}
    else
      respond_valid(side, request, path)
    end
  end

  defp respond_valid(side, _request, "/1.0") do
    sync(%{
      api_version: "1.0",
      auth: "trusted",
      public: false,
      api_extensions: extensions(),
      environment: %{
        server_name: side.name,
        server: "incus",
        server_version: "7.0.1",
        addresses: ["127.0.0.1:9", "10.0.2.15:8443"],
        certificate: side.certificate
      }
    })
  end

  defp respond_valid(side, %{method: "POST"} = request, _path) do
    body = Jason.decode!(request.body)
    record(side, {:post, side.name, request.target, body})

    descriptor =
      body["target"] || if(get_in(body, ["source", "mode"]) == "pull", do: body["source"])

    if is_map(descriptor), do: outbound(side, descriptor)
    if side.opts[:reply] == :lost, do: %{raw: ""}, else: accepted(side.name)
  end

  defp respond_valid(side, %{method: "DELETE"} = request, _path) do
    record(side, {:delete, side.name, request.target})
    accepted(side.name <> "-delete")
  end

  defp respond_valid(side, request, path) do
    cond do
      path == "/1.0/events" ->
        %{upgrade: &event_channel(request, &1, &2)}

      String.ends_with?(path, "/websocket") ->
        upgrade(side, request)

      String.starts_with?(path, "/1.0/operations/") ->
        operation_response(side)

      String.contains?(path, "/snapshots/") ->
        sync(model(:snapshot))

      String.starts_with?(path, "/1.0/instances/") ->
        sync(model(:instance))

      true ->
        sync(%{})
    end
  end

  defp operation_response(side) do
    await_channels(side, System.monotonic_time(:millisecond) + 4_000)

    error =
      side.opts[:failure] ||
        Enum.find_value(events(side), fn
          {:outbound, _, _, %{"error" => error}} -> error
          _ -> nil
        end) || if(not channels_complete?(side), do: "migration fixture channels incomplete")

    sync(%{
      id: side.name,
      status: if(error, do: "Failure", else: "Success"),
      status_code: if(error, do: 400, else: 200),
      err: error || "",
      may_cancel: false
    })
  end

  defp outbound(side, descriptor) do
    # Explicit guest reachability failure is a native operation error, never an
    # attempt by the gateway to follow a private address or replay this POST.
    unless side.opts[:failure] do
      spawn(fn ->
        result =
          run(side.root, %{
            Action: "server",
            Name: side.name,
            Operation: descriptor["operation"],
            Certificate: descriptor["certificate"],
            Websockets: descriptor["secrets"]
          })

        record(side, {:outbound, side.name, descriptor["operation"], result})
      end)
    end
  end

  defp upgrade(side, request) do
    query = URI.decode_query(URI.parse(request.target).query || "")
    channel = Enum.find(@channels, &(query["secret"] == side.name <> "-" <> &1))

    if channel do
      %{upgrade: &channel(side, request, channel, &1, &2)}
    else
      %{status: 403, body: %{type: "error", error: "native secret refused", error_code: 403}}
    end
  end

  defp channel(side, request, channel, transport, socket) do
    accept = Base.encode64(:crypto.hash(:sha, request.headers["sec-websocket-key"] <> @guid))

    :ok =
      transport.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
        accept,
        "\r\n\r\n",
        WebSocketFixture.frame(2, side.name <> ":" <> channel)
      ])

    receive_frames(side, channel, transport, socket)
  end

  defp receive_frames(side, channel, transport, socket) do
    with {:ok, <<_::4, opcode::4, 1::1, length::7>>} <- transport.recv(socket, 2, 4_000),
         true <- length <= 125,
         {:ok, <<mask::binary-size(4), payload::binary-size(length)>>} <-
           transport.recv(socket, 4 + length, 4_000) do
      data =
        payload
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
        |> :binary.list_to_bin()

      if opcode in [1, 2] do
        record(side, {:frame, side.name, channel, data})

        if side.name == "source",
          do: transport.send(socket, WebSocketFixture.frame(8, <<1000::16>>))

        receive_frames(side, channel, transport, socket)
      end
    end
  end

  defp event_channel(request, transport, socket) do
    accept = Base.encode64(:crypto.hash(:sha, request.headers["sec-websocket-key"] <> @guid))

    transport.send(socket, [
      "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
      accept,
      "\r\n\r\n"
    ])

    transport.recv(socket, 0, 10_000)
  end

  defp channels_complete?(side) do
    events = events(side)
    count = Enum.count(events, &match?({:frame, _, _, _}, &1))

    outbound =
      Enum.any?(events, fn
        {:outbound, _, _, %{"frames" => frames}} -> map_size(frames) == 2
        _ -> false
      end)

    count >= 4 or (outbound and count >= 2)
  end

  defp await_channels(side, deadline) do
    if not channels_complete?(side) and is_nil(side.opts[:failure]) and
         System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_channels(side, deadline)
    end
  end

  defp record(side, event), do: Agent.update(side.log, &[event | &1])

  defp sync(metadata),
    do: %{
      status: 200,
      body: %{type: "sync", status: "Success", status_code: 200, metadata: metadata}
    }

  defp accepted(name),
    do: %{
      status: 202,
      body: %{
        type: "async",
        status_code: 100,
        operation: "/1.0/operations/" <> name,
        metadata: %{
          id: name,
          class: "websocket",
          status: "Running",
          status_code: 103,
          may_cancel: true,
          metadata: Map.new(@channels, &{&1, name <> "-" <> &1})
        }
      }
    }
end
