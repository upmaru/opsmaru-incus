defmodule Opsmaru.TestSupport.HTTPFixture do
  @moduledoc """
  Bounded, scripted Unix/TLS HTTP endpoint for protocol fixtures only.
  Each connection serves one request; captured requests are authoritative.
  No fixture opens a Swift socket, invokes VZ or accesses ordinary state.
  """

  use GenServer
  alias Opsmaru.Incus.Connection
  alias Plug.Conn.Status

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def endpoint(pid), do: GenServer.call(pid, :endpoint)
  def requests(pid), do: GenServer.call(pid, :requests)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    transport = Keyword.fetch!(opts, :transport)

    {listener, endpoint} =
      case transport do
        :gen_tcp ->
          path = Keyword.fetch!(opts, :path)

          {:ok, listener} =
            :gen_tcp.listen(0, [
              :binary,
              ip: {:local, String.to_charlist(path)},
              active: false,
              packet: :raw
            ])

          File.chmod!(path, 0o600)
          {listener, %{socket: path}}

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

          {:ok, {_address, port}} = :ssl.sockname(listener)
          {listener, %{url: "https://localhost:#{port}"}}
      end

    owner = self()
    worker = spawn_link(fn -> accept_loop(transport, listener, owner) end)

    {:ok,
     %{
       transport: transport,
       listener: listener,
       worker: worker,
       endpoint: endpoint,
       handler: Keyword.fetch!(opts, :handler),
       requests: []
     }}
  end

  defp peer_options(opts) do
    options = Keyword.get(opts, :peer_options, [])

    case Keyword.pop(options, :cacertfile) do
      {nil, options} -> options
      {file, options} -> Keyword.put(options, :cacerts, Connection.ca_certificates(file))
    end
  end

  @impl true
  def handle_call(:endpoint, _from, state), do: {:reply, state.endpoint, state}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

  def handle_call({:request, request}, _from, state) do
    {:reply, state.handler, %{state | requests: [request | state.requests]}}
  end

  @impl true
  def handle_info({:EXIT, worker, reason}, %{worker: worker} = state),
    do: {:stop, {:fixture_worker_exited, reason}, state}

  @impl true
  def terminate(_reason, state) do
    state.transport.close(state.listener)
    Process.exit(state.worker, :shutdown)

    if state.transport == :gen_tcp do
      File.rm(state.endpoint.socket)
    end
  end

  defp accept_loop(transport, listener, owner) do
    accepted =
      case transport do
        :gen_tcp ->
          :gen_tcp.accept(listener)

        :ssl ->
          case :ssl.transport_accept(listener, 5_000) do
            {:ok, socket} ->
              case :ssl.handshake(socket, 5_000) do
                {:ok, socket} ->
                  {:ok, socket}

                {:error, _} ->
                  :ssl.close(socket)
                  {:error, :handshake_failed}
              end

            error ->
              error
          end
      end

    case accepted do
      {:ok, socket} ->
        worker =
          spawn_link(fn ->
            receive do
              {:socket, socket} -> serve(transport, socket, owner)
            end
          end)

        :ok = transport.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept_loop(transport, listener, owner)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        accept_loop(transport, listener, owner)

      {:error, _reason} ->
        accept_loop(transport, listener, owner)
    end
  end

  defp serve(transport, socket, owner) do
    request = read_request(transport, socket)
    handler = GenServer.call(owner, {:request, request})
    response = handler.(request)

    case response do
      %{upgrade: handler} when is_function(handler, 2) ->
        handler.(transport, socket)

      %{wire_chunks: chunks} ->
        Enum.reduce_while(chunks, :ok, fn {delay, bytes}, _ ->
          Process.sleep(delay)

          case transport.send(socket, bytes) do
            :ok -> {:cont, :ok}
            {:error, _} -> {:halt, :ok}
          end
        end)

      _ ->
        transport.send(socket, encode_response(response))
    end
  rescue
    # A bounded client may close while the fixture reads a body.
    MatchError -> :ok
  after
    transport.close(socket)
  end

  defp read_request(transport, socket) do
    {head, initial_body} = read_head(transport, socket, "")
    [line | headers] = String.split(head, "\r\n")
    [method, target, "HTTP/1.1"] = String.split(line, " ")

    headers =
      Map.new(headers, fn header ->
        [name, value] = String.split(header, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    length = String.to_integer(Map.get(headers, "content-length", "0"))
    if length > 1_048_576, do: raise("fixture request body too large")

    body =
      if headers["transfer-encoding"] == "chunked" do
        read_chunked(transport, socket, initial_body, [], 0)
      else
        if Map.has_key?(headers, "transfer-encoding"),
          do: raise("invalid fixture transfer encoding")

        read_body(transport, socket, initial_body, length)
      end

    %{method: method, target: target, headers: headers, body: body}
  end

  defp read_head(transport, socket, acc) do
    if byte_size(acc) > 65_536, do: raise("fixture headers too large")

    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        {head, body}

      [_] ->
        {:ok, data} = transport.recv(socket, 0, 5_000)
        read_head(transport, socket, acc <> data)
    end
  end

  defp read_body(_transport, _socket, body, length) when byte_size(body) == length, do: body

  defp read_body(transport, socket, body, length) when byte_size(body) < length do
    {:ok, data} = transport.recv(socket, length - byte_size(body), 5_000)
    read_body(transport, socket, body <> data, length)
  end

  defp read_chunked(transport, socket, buffer, chunks, count) do
    {line, buffer} = line(transport, socket, buffer)
    {size, ""} = Integer.parse(line, 16)
    if size < 0 or count + size > 1_048_576, do: raise("fixture chunk bound")

    if size == 0 do
      {"", _} = line(transport, socket, buffer)
      IO.iodata_to_binary(Enum.reverse(chunks))
    else
      buffer = at_least(transport, socket, buffer, size + 2)
      <<chunk::binary-size(size), "\r\n", rest::binary>> = buffer
      read_chunked(transport, socket, rest, [chunk | chunks], count + size)
    end
  end

  defp line(transport, socket, buffer) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        {line, rest}

      [_] ->
        if byte_size(buffer) > 65_536, do: raise("fixture line bound")
        {:ok, data} = transport.recv(socket, 0, 5_000)
        line(transport, socket, buffer <> data)
    end
  end

  defp at_least(_, _, buffer, size) when byte_size(buffer) >= size, do: buffer

  defp at_least(transport, socket, buffer, size) do
    {:ok, bytes} = transport.recv(socket, 0, 5_000)
    at_least(transport, socket, buffer <> bytes, size)
  end

  defp encode_response(%{raw: bytes}), do: bytes

  defp encode_response(response) do
    body = Jason.encode!(response.body)
    status = response.status

    headers =
      Enum.map(Map.get(response, :headers, %{}), fn {name, value} ->
        [name, ": ", value, "\r\n"]
      end)

    [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      Status.reason_phrase(status),
      "\r\n",
      "Content-Type: application/json\r\nContent-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\nConnection: close\r\n",
      headers,
      "\r\n",
      body
    ]
  end
end
