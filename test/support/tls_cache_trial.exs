# Isolated OTP 27 regression: never crash the parent suite's SSL manager.
alias Opsmaru.Incus.{Connection, Transport}
alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

[root] = System.argv()
identity = TLSIdentity.generate(root, "cache", "localhost")

{:ok, fixture} =
  HTTPFixture.start_link(
    transport: :ssl,
    certfile: identity.certfile,
    keyfile: identity.keyfile,
    handler: fn _ -> %{status: 200, body: %{}} end
  )

connection =
  Connection.https!(HTTPFixture.endpoint(fixture).url,
    owner: :fixture,
    tls: [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
  )

{:ok, socket} = Transport.open(connection, System.monotonic_time(:millisecond) + 5_000)
manager = Process.whereis(:ssl_manager)
cache = Process.whereis(:ssl_pem_cache)
File.rm!(identity.cafile)
GenServer.cast(:ssl_pem_cache, {:invalidate_pem, identity.cafile})
:sys.get_state(cache)

unless Process.whereis(:ssl_manager) == manager and Process.alive?(manager),
  do: raise("CA file eviction stopped the shared SSL manager")

Mint.HTTP.close(socket)
GenServer.stop(fixture)
IO.puts("Deleted CA refresh preserves SSL manager and closes the owned socket")
