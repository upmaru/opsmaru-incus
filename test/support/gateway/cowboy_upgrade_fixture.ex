defmodule Opsmaru.TestSupport.Gateway.CowboyUpgradeHandler do
  @moduledoc """
  Fixture-only Cowboy native-upgrade proof. Authentication is a fixed fixture
  client certificate; this is not the production credential/trust adapter.
  """

  @behaviour :cowboy_handler

  @impl true
  def init(req, opts) do
    protocol = :cowboy_req.header("upgrade", req)

    cond do
      :cowboy_req.cert(req) != opts.certificate ->
        reject(req, opts, 403)

      req.method == "GET" and req.path == "/1.0" and protocol == :undefined ->
        body =
          Jason.encode!(%{
            type: "sync",
            status: "Success",
            status_code: 200,
            metadata: %{
              api_version: "1.0",
              api_extensions: ["instance_nbd"],
              api_status: "stable",
              auth: "trusted",
              public: false,
              environment: %{}
            }
          })

        {:ok, :cowboy_req.reply(200, %{"content-type" => "application/json"}, body, req), opts}

      req.method != "GET" or req.version != :"HTTP/1.1" or
        protocol not in ["sftp", "nbd"] or
        "upgrade" not in :cowboy_req.parse_header("connection", req, []) or
          :cowboy_req.has_body(req) ->
        reject(req, opts, 400)

      true ->
        upgrade(req, opts, protocol)
    end
  end

  defp upgrade(req, opts, protocol) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(opts.path)},
           0,
           [
             :binary,
             active: false,
             exit_on_close: false,
             send_timeout: 1_000,
             send_timeout_close: true,
             buffer: 65_536
           ],
           1_000
         ) do
      {:ok, backend} ->
        target = req.path <> if(req.qs == "", do: "", else: "?" <> req.qs)

        request = [
          "GET ",
          target,
          " HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: ",
          protocol,
          "\r\n\r\n"
        ]

        with :ok <- :gen_tcp.send(backend, request),
             {:ok, head, buffer} <- read_head(backend, ""),
             true <- valid_reply?(head, protocol),
             :ok <- :gen_tcp.controlling_process(backend, req.pid) do
          state = %{backend: backend, backend_buffer: buffer, observer: opts.observer}
          headers = %{"connection" => "Upgrade", "upgrade" => protocol}

          :cowboy_req.cast(
            {:switch_protocol, headers, Opsmaru.TestSupport.Gateway.CowboyTunnel, state},
            req
          )

          {:ok, req, opts}
        else
          _ ->
            :gen_tcp.close(backend)
            reject(req, opts, 502)
        end

      {:error, _} ->
        reject(req, opts, 502)
    end
  end

  defp read_head(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, _body] when byte_size(head) > 8_192 ->
        {:error, :headers_too_large}

      [head, body] ->
        {:ok, head, body}

      [_] when byte_size(bytes) > 8_192 ->
        {:error, :headers_too_large}

      [_] ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, chunk} -> read_head(socket, bytes <> chunk)
          error -> error
        end
    end
  end

  defp valid_reply?(head, protocol) do
    [status | headers] = String.split(head, "\r\n")

    headers =
      Map.new(headers, fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> {String.downcase(name), String.trim(value)}
          _ -> {"invalid", ""}
        end
      end)

    String.starts_with?(status, "HTTP/1.1 101 ") and
      headers["upgrade"] == protocol and
      "upgrade" in String.split(String.downcase(headers["connection"] || ""), ~r/\s*,\s*/)
  end

  defp reject(req, opts, status) do
    {:ok,
     :cowboy_req.reply(
       status,
       %{"content-type" => "application/json"},
       Jason.encode!(%{error: "fixture upgrade rejected"}),
       req
     ), opts}
  end
end

defmodule Opsmaru.TestSupport.Gateway.CowboyTunnel do
  @moduledoc """
  Fixture-only socket takeover with one active read per direction.

  Each direction writes through its own writer process, so a write blocked on one
  peer never stops the tunnel reading the other. A single-process relay deadlocks
  when both peers write at once: blocked sending to a backend that is itself
  blocked echoing back, with only 8 KiB Unix socket buffers on macOS. A read is
  re-armed only after its bytes are written (per-direction backpressure), and a
  write still blocked after one second closes the tunnel.
  """

  # Cowboy calls this in its connection process after sending HTTP 101. Both
  # descriptors belong to that process, not the now-terminated request worker.
  def takeover(_parent, _ref, client, transport, _opts, buffer, state) do
    backend = state.backend
    send(state.observer, {:tunnel_started, self()})
    to_backend = writer()
    to_client = writer()

    try do
      :ok =
        transport.setopts(client, active: false, send_timeout: 1_000, send_timeout_close: true)

      :ok = :gen_tcp.send(backend, buffer)
      :ok = transport.send(client, state.backend_buffer)
      :ok = :inet.setopts(backend, active: :once)
      :ok = transport.setopts(client, active: :once)

      relay(%{
        client: client,
        transport: transport,
        backend: backend,
        to_backend: to_backend,
        to_client: to_client,
        pending: 0,
        client_closed: false,
        backend_closed: false
      })
    after
      Process.exit(to_backend, :kill)
      Process.exit(to_client, :kill)
      :gen_tcp.close(backend)
      transport.close(client)
      send(state.observer, {:tunnel_closed, self()})
    end

    # takeover/7 replaces the HTTP connection process for its entire lifetime.
    # Returning would incorrectly re-enter Cowboy's HTTP state machine.
    exit(:normal)
  end

  # Runs one direction's writes in order and reports each result to the tunnel.
  defp writer do
    tunnel = self()

    spawn(fn ->
      monitor = Process.monitor(tunnel)
      write_loop(tunnel, monitor)
    end)
  end

  defp write_loop(tunnel, monitor) do
    receive do
      {:write, tag, write} ->
        send(tunnel, {:written, tag, write.()})
        write_loop(tunnel, monitor)

      {:DOWN, ^monitor, :process, _, _} ->
        :ok
    end
  end

  # Both peers closed and every queued write (data, then shutdown) finished.
  defp relay(%{client_closed: true, backend_closed: true, pending: 0}), do: :ok

  defp relay(%{client: client, transport: transport, backend: backend} = state) do
    timeout = if state.client_closed or state.backend_closed, do: 1_000, else: 5_000

    receive do
      {:ssl, ^client, bytes} ->
        relay(write(state, :to_backend, :client_bytes, fn -> :gen_tcp.send(backend, bytes) end))

      {:tcp, ^backend, bytes} ->
        relay(write(state, :to_client, :backend_bytes, fn -> transport.send(client, bytes) end))

      {:written, :client_bytes, :ok} ->
        if state.client_closed or transport.setopts(client, active: :once) == :ok,
          do: relay(%{state | pending: state.pending - 1})

      {:written, :backend_bytes, :ok} ->
        if state.backend_closed or :inet.setopts(backend, active: :once) == :ok,
          do: relay(%{state | pending: state.pending - 1})

      # A data write failed or stayed blocked past its send timeout.
      {:written, tag, _} when tag in [:client_bytes, :backend_bytes] ->
        :ok

      {:written, :shutdown, _} ->
        relay(%{state | pending: state.pending - 1})

      {:ssl_closed, ^client} ->
        state = write(state, :to_backend, :shutdown, fn -> :gen_tcp.shutdown(backend, :write) end)
        relay(%{state | client_closed: true})

      {:tcp_closed, ^backend} ->
        state = write(state, :to_client, :shutdown, fn -> transport.shutdown(client, :write) end)
        relay(%{state | backend_closed: true})

      {:ssl_error, ^client, _} ->
        :ok

      {:tcp_error, ^backend, _} ->
        :ok
    after
      timeout -> :ok
    end
  end

  defp write(state, direction, tag, fun) do
    send(Map.fetch!(state, direction), {:write, tag, fun})
    %{state | pending: state.pending + 1}
  end
end

defmodule Opsmaru.TestSupport.Gateway.NativeBackend do
  @moduledoc "Isolated Unix HTTP-upgrade/opaque-byte backend for the Cowboy trial."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def accepted(pid), do: GenServer.call(pid, :accepted)

  @impl true
  def init(opts) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ip: {:local, String.to_charlist(opts.path)},
        exit_on_close: false
      ])

    File.chmod!(opts.path, 0o600)
    owner = self()
    acceptor = spawn_link(fn -> accept_loop(listener, owner, opts) end)
    {:ok, %{listener: listener, acceptor: acceptor, accepted: 0}}
  end

  @impl true
  def handle_call(:accepted, _from, state), do: {:reply, state.accepted, state}

  @impl true
  def handle_cast(:accepted, state), do: {:noreply, %{state | accepted: state.accepted + 1}}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    Process.exit(state.acceptor, :shutdown)
  end

  defp accept_loop(listener, owner, opts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        GenServer.cast(owner, :accepted)

        worker =
          spawn_link(fn ->
            receive do
              {:socket, socket} -> serve(socket, opts)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept_loop(listener, owner, opts)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, opts) do
    try do
      {head, body} = read_head(socket, "")
      send(opts.observer, {:backend_request, head})
      protocol = opts.protocol
      reply_protocol = Map.get(opts, :reply_protocol, protocol)

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: ",
          reply_protocol,
          "\r\n\r\n",
          opts.initial
        ])

      if Map.get(opts, :half_close, false), do: :gen_tcp.shutdown(socket, :write)
      echo(socket, body, opts)
    after
      :gen_tcp.close(socket)
      send(opts.observer, {:backend_closed, self()})
    end
  end

  defp read_head(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, _body] when byte_size(head) > 8_192 ->
        raise("oversized fixture handshake")

      [head, body] ->
        {head, body}

      [_] when byte_size(bytes) > 8_192 ->
        raise("oversized fixture handshake")

      [_] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
        read_head(socket, bytes <> chunk)
    end
  end

  defp echo(socket, bytes, opts) do
    if bytes != "" do
      send(opts.observer, {:backend_bytes, bytes})
      unless Map.get(opts, :half_close, false), do: :gen_tcp.send(socket, bytes)
    end

    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> echo(socket, chunk, opts)
      {:error, _} -> :ok
    end
  end
end
