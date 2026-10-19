defmodule Opsmaru.TestSupport.WebSocketFixture do
  @moduledoc "Independent bounded RFC6455 fixture, not an Incus workload or Macus proxy."
  use GenServer
  alias Opsmaru.Incus.Connection
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def path(pid), do: GenServer.call(pid, :path)
  def endpoint(pid), do: GenServer.call(pid, :endpoint)
  def requests(pid), do: GenServer.call(pid, :requests)
  @impl true
  def init(opts) do
    {transport, listener, endpoint} = listen(opts)
    opts = Keyword.put(opts, :transport, transport)
    owner = self()
    worker = spawn_link(fn -> accept(listener, owner, opts) end)

    {:ok,
     %{
       path: endpoint[:socket],
       endpoint: endpoint,
       transport: transport,
       listener: listener,
       worker: worker,
       requests: []
     }}
  end

  # Unix by default; `transport: :ssl` serves verified (optionally mutual) TLS on loopback.
  defp listen(opts) do
    case Keyword.get(opts, :transport, :gen_tcp) do
      :gen_tcp ->
        path = Keyword.fetch!(opts, :path)

        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

        File.chmod!(path, 0o600)
        {:gen_tcp, listener, %{socket: path}}

      :ssl ->
        {:ok, _} = Application.ensure_all_started(:ssl)

        {:ok, listener} =
          :ssl.listen(
            0,
            [
              :binary,
              ip: {127, 0, 0, 1},
              active: false,
              certfile: String.to_charlist(Keyword.fetch!(opts, :certfile)),
              keyfile: String.to_charlist(Keyword.fetch!(opts, :keyfile)),
              versions: [:"tlsv1.3"],
              reuseaddr: true
            ] ++ peer_options(opts)
          )

        {:ok, {_, port}} = :ssl.sockname(listener)
        {:ssl, listener, %{url: "https://localhost:#{port}"}}
    end
  end

  defp peer_options(opts) do
    case Keyword.pop(Keyword.get(opts, :peer_options, []), :cacertfile) do
      {nil, options} ->
        options

      {file, options} ->
        Keyword.put(options, :cacerts, Connection.ca_certificates(file))
    end
  end

  @impl true
  def handle_call(:path, _, state), do: {:reply, state.path, state}
  def handle_call(:endpoint, _, state), do: {:reply, state.endpoint, state}
  def handle_call(:requests, _, state), do: {:reply, Enum.reverse(state.requests), state}

  def handle_call({:request, request}, _, state),
    do: {:reply, :ok, %{state | requests: [request | state.requests]}}

  @impl true
  def terminate(_, state) do
    state.transport.close(state.listener)
    Process.exit(state.worker, :shutdown)
    if state.path, do: File.rm(state.path)
  end

  defp accept(listener, owner, opts) do
    case accept_socket(opts[:transport], listener) do
      {:ok, socket} ->
        worker =
          spawn(fn ->
            receive do
              {:socket, socket} -> serve(socket, owner, opts)
            end
          end)

        :ok = opts[:transport].controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept(listener, owner, opts)

      {:error, :handshake_failed} ->
        accept(listener, owner, opts)

      _ ->
        :ok
    end
  end

  defp accept_socket(:gen_tcp, listener), do: :gen_tcp.accept(listener)

  defp accept_socket(:ssl, listener) do
    with {:ok, socket} <- :ssl.transport_accept(listener) do
      case :ssl.handshake(socket, 5_000) do
        {:ok, socket} ->
          {:ok, socket}

        {:error, _} ->
          :ssl.close(socket)
          {:error, :handshake_failed}
      end
    end
  end

  defp serve(socket, owner, opts) do
    t = opts[:transport]
    {header, initial} = header(t, socket, "")
    [request | lines] = String.split(header, "\r\n", trim: true)
    [method, target, _] = String.split(request, " ")

    headers =
      Map.new(lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    length = String.to_integer(headers["content-length"] || "0")

    body =
      if byte_size(initial) < length do
        {:ok, rest} = t.recv(socket, length - byte_size(initial), 5_000)
        initial <> rest
      else
        initial
      end

    request = %{method: method, target: target, headers: headers, body: body}
    :ok = GenServer.call(owner, {:request, request})

    if URI.parse(target).path == "/1.0" do
      body =
        Jason.encode!(%{
          type: "sync",
          metadata: %{
            api_version: "1.0",
            api_extensions: Keyword.get(opts, :api_extensions, []),
            environment: %{}
          }
        })

      t.send(socket, [
        "HTTP/1.1 200 OK\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])
    else
      if not Map.has_key?(headers, "sec-websocket-key") and opts[:http_handler] do
        response = opts[:http_handler].(request)
        body = Jason.encode!(response.body)

        t.send(socket, [
          "HTTP/1.1 ",
          Integer.to_string(response.status),
          " OK\r\nContent-Length: ",
          Integer.to_string(byte_size(body)),
          "\r\n\r\n",
          body
        ])
      else
        accept =
          Base.encode64(
            :crypto.hash(
              :sha,
              headers["sec-websocket-key"] <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            )
          )

        bytes = Keyword.get(opts, :wire, frame(2, <<0, 255, 128>>))

        Process.sleep(Keyword.get(opts, :upgrade_delay, 0))

        :ok =
          t.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
            accept,
            "\r\n\r\n",
            bytes
          ])

        close_later(t, socket, opts[:close_after])

        echo(socket, opts)
      end
    end
  rescue
    _ -> :ok
  after
    opts[:transport].close(socket)
  end

  defp close_later(_, _, nil), do: :ok

  defp close_later(t, socket, delay) do
    spawn(fn ->
      Process.sleep(delay)
      t.send(socket, frame(8, <<1000::16>>))
    end)
  end

  defp header(t, socket, bytes) do
    if byte_size(bytes) > 65_536, do: raise("fixture header budget")

    case :binary.split(bytes, "\r\n\r\n") do
      [header, rest] ->
        {header, rest}

      [_] ->
        {:ok, next} = t.recv(socket, 0, 5_000)
        header(t, socket, bytes <> next)
    end
  end

  def frame(opcode, bytes) when byte_size(bytes) <= 125,
    do: <<1::1, 0::3, opcode::4, 0::1, byte_size(bytes)::7, bytes::binary>>

  def frame(opcode, bytes) when byte_size(bytes) <= 65_535,
    do: <<1::1, 0::3, opcode::4, 0::1, 126::7, byte_size(bytes)::16, bytes::binary>>

  # Masked client frames with 7-bit or 16-bit payload lengths.
  defp recv_header(t, socket) do
    case t.recv(socket, 2, 5_000) do
      {:ok, <<_fin::1, _::3, opcode::4, 1::1, 126::7>>} ->
        with {:ok, <<length::16>>} <- t.recv(socket, 2, 5_000), do: {:ok, opcode, length}

      {:ok, <<_fin::1, _::3, opcode::4, 1::1, length::7>>} when length <= 125 ->
        {:ok, opcode, length}

      {:error, reason} ->
        {:error, reason}

      _ ->
        :error
    end
  end

  defp echo(socket, opts) do
    t = opts[:transport]

    case recv_header(t, socket) do
      {:ok, opcode, length} ->
        {:ok, <<mask::binary-size(4), payload::binary-size(length)>>} =
          t.recv(socket, 4 + length, 5_000)

        data =
          payload
          |> :binary.bin_to_list()
          |> Enum.with_index()
          |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
          |> :binary.list_to_bin()

        if opcode != 8 do
          cond do
            opts[:response_frames] -> t.send(socket, opts[:response_frames].(opcode, data))
            opts[:frame_handler] -> opts[:frame_handler].(opcode, data)
            true -> t.send(socket, frame(opcode, data))
          end

          echo(socket, opts)
        else
          peer(opts, :close_frame)
        end

      {:error, :closed} ->
        peer(opts, :closed)

      _ ->
        peer(opts, :idle_or_invalid)
    end
  end

  # Optional observation of how the client ended the stream, for peer-closure evidence.
  defp peer(opts, outcome), do: if(pid = opts[:notify], do: send(pid, {:websocket_peer, outcome}))
end
