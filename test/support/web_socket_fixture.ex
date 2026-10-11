defmodule Opsmaru.TestSupport.WebSocketFixture do
  @moduledoc "Independent bounded RFC6455 fixture, not an Incus workload or Macus proxy."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def path(pid), do: GenServer.call(pid, :path)
  def requests(pid), do: GenServer.call(pid, :requests)
  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)
    owner = self()
    worker = spawn_link(fn -> accept(listener, owner, opts) end)
    {:ok, %{path: path, listener: listener, worker: worker, requests: []}}
  end

  @impl true
  def handle_call(:path, _, state), do: {:reply, state.path, state}
  def handle_call(:requests, _, state), do: {:reply, Enum.reverse(state.requests), state}

  def handle_call({:request, request}, _, state),
    do: {:reply, :ok, %{state | requests: [request | state.requests]}}

  @impl true
  def terminate(_, state) do
    :gen_tcp.close(state.listener)
    Process.exit(state.worker, :shutdown)
    File.rm(state.path)
  end

  defp accept(listener, owner, opts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        worker =
          spawn(fn ->
            receive do
              {:socket, socket} -> serve(socket, owner, opts)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept(listener, owner, opts)

      _ ->
        :ok
    end
  end

  defp serve(socket, owner, opts) do
    {header, initial} = header(socket, "")
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
        {:ok, rest} = :gen_tcp.recv(socket, length - byte_size(initial), 5_000)
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

      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])
    else
      if not Map.has_key?(headers, "sec-websocket-key") and opts[:http_handler] do
        response = opts[:http_handler].(request)
        body = Jason.encode!(response.body)

        :gen_tcp.send(socket, [
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

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
            accept,
            "\r\n\r\n",
            bytes
          ])

        close_later(socket, opts[:close_after])

        echo(socket, opts)
      end
    end
  rescue
    _ -> :ok
  after
    :gen_tcp.close(socket)
  end

  defp close_later(_, nil), do: :ok

  defp close_later(socket, delay) do
    spawn(fn ->
      Process.sleep(delay)
      :gen_tcp.send(socket, frame(8, <<1000::16>>))
    end)
  end

  defp header(socket, bytes) do
    if byte_size(bytes) > 65_536, do: raise("fixture header budget")

    case :binary.split(bytes, "\r\n\r\n") do
      [header, rest] ->
        {header, rest}

      [_] ->
        {:ok, next} = :gen_tcp.recv(socket, 0, 5_000)
        header(socket, bytes <> next)
    end
  end

  def frame(opcode, bytes) when byte_size(bytes) <= 125,
    do: <<1::1, 0::3, opcode::4, 0::1, byte_size(bytes)::7, bytes::binary>>

  def frame(opcode, bytes) when byte_size(bytes) <= 65_535,
    do: <<1::1, 0::3, opcode::4, 0::1, 126::7, byte_size(bytes)::16, bytes::binary>>

  defp echo(socket, opts) do
    case :gen_tcp.recv(socket, 2, 5_000) do
      {:ok, <<_fin::1, _::3, opcode::4, 1::1, length::7>>} when length <= 125 ->
        {:ok, <<mask::binary-size(4), payload::binary-size(length)>>} =
          :gen_tcp.recv(socket, 4 + length, 5_000)

        data =
          payload
          |> :binary.bin_to_list()
          |> Enum.with_index()
          |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
          |> :binary.list_to_bin()

        if opcode != 8 do
          if opts[:frame_handler],
            do: opts[:frame_handler].(opcode, data),
            else: :gen_tcp.send(socket, frame(opcode, data))

          echo(socket, opts)
        end

      _ ->
        :ok
    end
  end
end
