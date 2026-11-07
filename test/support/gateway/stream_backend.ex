defmodule Opsmaru.TestSupport.StreamBackend do
  @moduledoc """
  Scriptable fake Incus backend over a private Unix socket or TLS, for gateway
  protocol fixtures only. Each accepted connection reports
  `{:backend_request, %{method, target, headers}}` to the observer and runs
  `script.(conn)` with helpers to read bodies of any size (hashing, never
  capturing) and write raw response bytes. Accepted connections are counted.
  """

  use GenServer
  alias Opsmaru.Incus.Connection

  defstruct [:transport, :socket, :buffer, :observer, :head]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def accepted(pid), do: GenServer.call(pid, :accepted)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    observer = Keyword.fetch!(opts, :observer)
    script = Keyword.fetch!(opts, :script)

    {transport, listener} =
      case Keyword.fetch(opts, :path) do
        {:ok, path} ->
          {:ok, listener} =
            :gen_tcp.listen(0, [
              :binary,
              ip: {:local, String.to_charlist(path)},
              active: false,
              exit_on_close: false
            ])

          File.chmod!(path, 0o600)
          {:gen_tcp, listener}

        :error ->
          identity = Keyword.fetch!(opts, :tls)

          {:ok, listener} =
            :ssl.listen(0, [
              :binary,
              ip: {127, 0, 0, 1},
              active: false,
              certfile: String.to_charlist(identity.certfile),
              keyfile: String.to_charlist(identity.keyfile),
              versions: [:"tlsv1.3"],
              reuseaddr: true,
              verify: :verify_peer,
              fail_if_no_peer_cert: true,
              cacerts: Connection.ca_certificates(Keyword.fetch!(opts, :client_ca))
            ])

          {:ssl, listener}
      end

    owner = self()
    acceptor = spawn_link(fn -> accept_loop(transport, listener, owner, observer, script) end)
    {:ok, %{transport: transport, listener: listener, acceptor: acceptor, accepted: 0}}
  end

  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def handle_call(:accepted, _from, state), do: {:reply, state.accepted, state}

  def handle_call(:port, _from, state) do
    {:ok, {_, port}} = :ssl.sockname(state.listener)
    {:reply, port, state}
  end

  @impl true
  def handle_cast(:accepted, state), do: {:noreply, %{state | accepted: state.accepted + 1}}

  @impl true
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    state.transport.close(state.listener)
    Process.exit(state.acceptor, :kill)
  end

  defp accept_loop(transport, listener, owner, observer, script) do
    case accept(transport, listener) do
      {:ok, socket} ->
        GenServer.cast(owner, :accepted)

        worker =
          spawn(fn ->
            receive do
              {:socket, socket} -> serve(transport, socket, observer, script)
            end
          end)

        :ok = transport.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept_loop(transport, listener, owner, observer, script)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept_loop(transport, listener, owner, observer, script)
    end
  end

  defp accept(:gen_tcp, listener), do: :gen_tcp.accept(listener)

  defp accept(:ssl, listener) do
    with {:ok, socket} <- :ssl.transport_accept(listener, 5_000) do
      :ssl.handshake(socket, 5_000)
    end
  end

  defp serve(transport, socket, observer, script) do
    conn = %__MODULE__{transport: transport, socket: socket, buffer: "", observer: observer}

    try do
      conn = read_head(conn)
      send(observer, {:backend_request, conn.head})
      script.(conn)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    after
      transport.close(socket)
      send(observer, {:backend_closed, self()})
    end
  end

  defp read_head(conn) do
    case :binary.split(conn.buffer, "\r\n\r\n") do
      [head, rest] ->
        [line | fields] = String.split(head, "\r\n")
        [method, target, "HTTP/1.1"] = String.split(line, " ")

        headers =
          Enum.map(fields, fn field ->
            [name, value] = String.split(field, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        %{conn | buffer: rest, head: %{method: method, target: target, headers: headers}}

      [_] ->
        if byte_size(conn.buffer) > 65_536, do: raise("fixture head too large")
        read_head(%{conn | buffer: conn.buffer <> recv!(conn)})
    end
  end

  @doc "Read the whole request body, returning `{conn, sha256, size}`."
  def read_body(conn) do
    headers = conn.head.headers

    cond do
      List.keyfind(headers, "transfer-encoding", 0) ->
        read_chunked(conn, :crypto.hash_init(:sha256), 0)

      found = List.keyfind(headers, "content-length", 0) ->
        read_length(conn, String.to_integer(elem(found, 1)), :crypto.hash_init(:sha256), 0)

      true ->
        {conn, :crypto.hash_final(:crypto.hash_init(:sha256)), 0}
    end
  end

  defp read_length(conn, length, hash, size) when size == length,
    do: {conn, :crypto.hash_final(hash), size}

  defp read_length(conn, length, hash, size) do
    conn = if conn.buffer == "", do: %{conn | buffer: recv!(conn)}, else: conn
    take = min(byte_size(conn.buffer), length - size)
    <<data::binary-size(take), rest::binary>> = conn.buffer
    read_length(%{conn | buffer: rest}, length, :crypto.hash_update(hash, data), size + take)
  end

  defp read_chunked(conn, hash, size) do
    {line, conn} = line(conn)
    {chunk, ""} = Integer.parse(line, 16)

    if chunk == 0 do
      {"", conn} = line(conn)
      {conn, :crypto.hash_final(hash), size}
    else
      conn = at_least(conn, chunk + 2)
      <<data::binary-size(chunk), "\r\n", rest::binary>> = conn.buffer
      read_chunked(%{conn | buffer: rest}, :crypto.hash_update(hash, data), size + chunk)
    end
  end

  defp line(conn) do
    case :binary.split(conn.buffer, "\r\n") do
      [line, rest] -> {line, %{conn | buffer: rest}}
      [_] -> line(%{conn | buffer: conn.buffer <> recv!(conn)})
    end
  end

  defp at_least(conn, size) when byte_size(conn.buffer) >= size, do: conn
  defp at_least(conn, size), do: at_least(%{conn | buffer: conn.buffer <> recv!(conn)}, size)

  defp recv!(conn) do
    {:ok, data} = conn.transport.recv(conn.socket, 0, 10_000)
    data
  end

  @doc "Write raw bytes; returns `:ok` or `{:error, reason}`."
  def write(conn, bytes), do: conn.transport.send(conn.socket, bytes)

  @doc "Wait until the peer closes, up to `timeout`."
  def await_close(conn, timeout \\ 5_000) do
    case conn.transport.recv(conn.socket, 0, timeout) do
      {:ok, _} -> await_close(conn, timeout)
      {:error, reason} -> reason
    end
  end

  @doc "A complete JSON response with content-length."
  def json(status, body, headers \\ []) do
    body = Jason.encode!(body)

    [
      "HTTP/1.1 #{status} Status\r\ncontent-type: application/json\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n",
      body
    ]
  end
end

defmodule Opsmaru.TestSupport.RawHTTP do
  @moduledoc """
  Minimal raw HTTP/1.1 client for gateway fixtures. It reads until the server
  closes and reports whether a chunked or sized body was complete, so a
  truncated response is never mistaken for a finished one.
  """
  alias Opsmaru.Incus.Connection

  def connect(port, tls \\ nil)

  def connect(port, nil) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, exit_on_close: false])

    {:gen_tcp, socket}
  end

  def connect(port, opts) do
    opts =
      case Keyword.pop(opts, :cacertfile) do
        {nil, opts} -> opts
        {file, opts} -> Keyword.put(opts, :cacerts, Connection.ca_certificates(file))
      end

    {:ok, socket} = :ssl.connect(~c"localhost", port, [:binary, active: false] ++ opts, 5_000)
    {:ssl, socket}
  end

  def send!({transport, socket}, bytes), do: :ok = transport.send(socket, bytes)

  def request(port, method, target, headers \\ [], body \\ "", tls \\ nil) do
    client = connect(port, tls)

    framing =
      if body == "" and method in ["GET", "HEAD", "DELETE"],
        do: [],
        else: [{"content-length", Integer.to_string(IO.iodata_length(body))}]

    send!(client, head(method, target, headers ++ framing ++ [{"connection", "close"}]))
    if IO.iodata_length(body) > 0, do: send!(client, body)
    read(client, method)
  end

  def head(method, target, headers) do
    [
      method,
      " ",
      target,
      " HTTP/1.1\r\nhost: localhost\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
  end

  def read({transport, socket}, method \\ "GET", timeout \\ 10_000) do
    bytes = read_all(transport, socket, "", timeout)
    transport.close(socket)
    parse(bytes, method)
  end

  defp read_all(transport, socket, acc, timeout) do
    case transport.recv(socket, 0, timeout) do
      {:ok, data} -> read_all(transport, socket, acc <> data, timeout)
      {:error, _} -> acc
    end
  end

  def parse(bytes, method \\ "GET") do
    [head, rest] = :binary.split(bytes, "\r\n\r\n")
    [status_line | fields] = String.split(head, "\r\n")
    ["HTTP/1.1", status | _] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.map(fields, fn field ->
        [name, value] = String.split(field, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    status = String.to_integer(status)

    {body, complete, trailers} =
      cond do
        method == "HEAD" or status in [204, 304] ->
          {"", true, []}

        List.keyfind(headers, "transfer-encoding", 0) ->
          dechunk(rest, [])

        found = List.keyfind(headers, "content-length", 0) ->
          length = String.to_integer(elem(found, 1))
          {binary_part(rest, 0, min(length, byte_size(rest))), byte_size(rest) == length, []}

        true ->
          {rest, true, []}
      end

    %{status: status, headers: headers, body: body, complete: complete, trailers: trailers}
  end

  defp dechunk(bytes, acc) do
    with [line, rest] <- :binary.split(bytes, "\r\n"),
         {size, ""} <- Integer.parse(line, 16) do
      if size == 0 do
        case :binary.split(rest, "\r\n\r\n") do
          [trailers, _] -> {IO.iodata_to_binary(Enum.reverse(acc)), true, fields(trailers)}
          _ when rest == "\r\n" -> {IO.iodata_to_binary(Enum.reverse(acc)), true, []}
          _ -> {IO.iodata_to_binary(Enum.reverse(acc)), String.starts_with?(rest, "\r\n"), []}
        end
      else
        case rest do
          <<chunk::binary-size(size), "\r\n", rest::binary>> -> dechunk(rest, [chunk | acc])
          _ -> {IO.iodata_to_binary(Enum.reverse(acc)), false, []}
        end
      end
    else
      _ -> {IO.iodata_to_binary(Enum.reverse(acc)), false, []}
    end
  end

  defp fields(""), do: []

  defp fields(block) do
    for field <- String.split(block, "\r\n"), field != "" do
      [name, value] = String.split(field, ":", parts: 2)
      {String.downcase(name), String.trim(value)}
    end
  end

  def header(response, name) do
    for {^name, value} <- response.headers, do: value
  end
end
