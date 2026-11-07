# Deliberately isolated: an OTP cache regression must not kill the test VM's SSL manager.
alias Opsmaru.Incus.{Connection, Transport}
alias Opsmaru.TestSupport.{GatewayServer, RawHTTP, StreamBackend, TLSIdentity}

[root] = System.argv()
Logger.configure(level: :none)
{:ok, _} = Application.ensure_all_started(:opsmaru_incus)
{:ok, _} = Application.ensure_all_started(:plug_cowboy)
:ok = GatewayServer.init()
server = TLSIdentity.generate(root, "server", "localhost")
client = TLSIdentity.generate(root, "client", "caller")
{ref, port} = GatewayServer.start_https(server, client.cafile)

frontend =
  RawHTTP.connect(port,
    verify: :verify_peer,
    cacertfile: server.cafile,
    certfile: String.to_charlist(client.certfile),
    keyfile: String.to_charlist(client.keyfile),
    server_name_indication: ~c"localhost"
  )

{:ok, backend} =
  StreamBackend.start_link(
    tls: server,
    client_ca: client.cafile,
    observer: self(),
    script: fn conn ->
      StreamBackend.write(conn, StreamBackend.json(200, %{}))
      StreamBackend.await_close(conn)
    end
  )

connection =
  Connection.https!("https://localhost:#{StreamBackend.port(backend)}",
    owner: :fixture,
    tls: [cacertfile: server.cafile, certfile: client.certfile, keyfile: client.keyfile]
  )

{:ok, socket} = Transport.open(connection, System.monotonic_time(:millisecond) + 5_000)
manager = Process.whereis(:ssl_manager)
monitor = Process.monitor(manager)

for path <- [server.cafile, client.cafile] do
  File.rm!(path)
  GenServer.cast(:ssl_pem_cache, {:invalidate_pem, path})
end

# Barrier for invalidation/refresh, rather than waiting for OTP's two-minute sweep.
:sys.get_state(:ssl_pem_cache)

receive do
  {:DOWN, ^monitor, :process, ^manager, _} ->
    raise "gateway CA-file eviction stopped the shared SSL manager"
after
  50 -> :ok
end

unless Process.whereis(:ssl_manager) == manager and Process.alive?(manager),
  do: raise("gateway CA-file eviction replaced the shared SSL manager")

:ok = RawHTTP.send!(frontend, "GET /1.0 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
%{status: 503, complete: true} = RawHTTP.read(frontend)
{:ok, socket, request} = Mint.HTTP.request(socket, "GET", "/1.0", [], nil)

collect = fn collect, socket, messages ->
  if Enum.any?(messages, &match?({:done, ^request}, &1)) do
    {socket, messages}
  else
    {:ok, socket, received} = Mint.HTTP.recv(socket, 0, 5_000)
    collect.(collect, socket, messages ++ received)
  end
end

{socket, messages} = collect.(collect, socket, [])
true = Enum.any?(messages, &match?({:status, ^request, 200}, &1))
"{}" = for({:data, ^request, data} <- messages, into: "", do: data)
Mint.HTTP.close(socket)
GatewayServer.stop(ref)
GenServer.stop(backend)
IO.puts("Gateway TLS fixtures retain their original SSL manager after CA-file eviction")
