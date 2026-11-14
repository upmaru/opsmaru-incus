defmodule Opsmaru.Incus.ConnectionPoolTest do
  use ExUnit.Case, async: false

  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, ConnectionPool, Context, Error, RequestContext, WorkScope}
  alias Opsmaru.Incus.ConnectionPool.TLS
  alias Opsmaru.Incus.Transport
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  @response ~s({"type":"sync","metadata":{"ready":true}})
  @timeout 5_000

  setup do
    root = Path.join(System.tmp_dir!(), "pool-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, identity: TLSIdentity.generate(root, "pool", "localhost")}
  end

  test "reuses GET and HEAD across project and identity changes, with a fresh mutation", env do
    {connection, context, _fixture} = start_pool(env)

    assert Connection.with_context(connection, RequestContext.new!(timeout: 500)).pool ==
             connection.pool

    assert Connection.member(connection, "target").pool == connection.pool

    assert {:ok, _} = query(connection, context)
    first = peer()
    selected = Connection.project(connection, "other")

    assert {:error, %Error{kind: :invalid_envelope}} =
             query(selected, %{context | identity: :another}, "HEAD")

    assert_receive {:request, ^first, "HEAD", "/1.0/probe?project=other"}, @timeout
    assert {:ok, _} = query(connection, context, "POST")
    refute peer() == first
    assert {:ok, _} = query(connection, context)
    assert peer() == first
  end

  test "denies requests before binding admission or TLS file reads", env do
    {connection, context, fixture} = start_pool(env)
    File.rm!(env.identity.keyfile)

    assert {:error, %Error{kind: :host_not_ready}} =
             query(connection, %{context | ready?: fn -> false end})

    assert {:error, %Error{kind: :owner_mismatch}} = query(connection, %{context | owner: :other})
    assert {:error, %Error{kind: :connection}} = query(connection, context)
    assert HTTPFixture.requests(fixture) == []
    assert :sys.get_state(connection.pool).bindings == %{}
  end

  test "trust bytes, server pin, and HTTPS origin distinguish bindings", env do
    {connection, _context, _fixture} = start_pool(env)
    {:ok, original, _} = TLS.snapshot(connection)
    digest = String.duplicate("a", 64)
    address = %{connection.address | port: connection.address.port + 1}
    tls = Keyword.put(connection.tls, :fingerprint, digest)

    assert {:ok, other_origin, _} = TLS.snapshot(%{connection | address: address})
    assert {:ok, pinned, _} = TLS.snapshot(%{connection | tls: tls})

    File.write!(env.identity.cafile, "\n", [:append])
    assert {:ok, changed_ca, _} = TLS.snapshot(connection)
    assert length(Enum.uniq([original, other_origin, pinned, changed_ca])) == 4
  end

  test "owner, authentication requirement and credential rotations isolate idle sockets", env do
    rotated = TLSIdentity.generate(env.root, "rotated", "localhost")
    {connection, context, _fixture} = start_pool(env, [], [rotated.cafile])
    assert {:ok, _} = query(connection, context)
    first = peer()

    assert {:ok, _} = query(%{connection | owner: :other}, %{context | owner: :other})
    refute peer() == first
    assert {:ok, _} = query(%{connection | require_authenticated: true}, context)
    refute peer() == first

    File.cp!(rotated.certfile, env.identity.certfile)
    assert {:error, %Error{kind: :connection}} = query(connection, context)
    refute_receive {:request, _, _, _}

    File.cp!(rotated.keyfile, env.identity.keyfile)
    assert {:ok, _} = query(connection, context)
    new_peer = peer()
    refute new_peer == first
    # The fixture records the credential presented during the actual handshake.
    assert_receive {:certificate, ^new_peer, cert}, @timeout

    [{:Certificate, ^cert, :not_encrypted}] =
      :public_key.pem_decode(File.read!(rotated.certfile))
  end

  test "saturation opens a fresh connection and pool shutdown lets in-flight reads finish", env do
    {connection, context, _fixture} = start_pool(env, size: 1)
    assert {:ok, _} = query(connection, context)
    first = peer()

    in_flight = Task.async(fn -> query(connection, context, "GET", "/1.0/hold") end)
    assert_receive {:request, ^first, "GET", "/1.0/hold"}, @timeout
    assert {:ok, _} = query(connection, context)
    refute peer() == first
    GenServer.stop(connection.pool)
    send(first, :release)
    assert {:ok, _} = Task.await(in_flight)
    assert {:ok, _} = query(connection, context)
    refute peer() == first
  end

  test "stopped, blocked, and full pool managers fall back before dispatch", env do
    {connection, context, fixture} = start_pool(env, max_bindings: 1)
    assert {:ok, _} = query(connection, context)
    first = peer()
    [binding] = Map.values(:sys.get_state(connection.pool).bindings)

    :ok = :sys.suspend(binding)

    try do
      assert {:ok, _} = query(connection, context)
      refute peer() == first
    after
      :ok = :sys.resume(binding)
    end

    assert {:ok, _} = query(%{connection | owner: :other}, %{context | owner: :other})
    refute peer() == first
    assert map_size(:sys.get_state(connection.pool).bindings) == 1
    GenServer.stop(connection.pool)
    assert {:ok, _} = query(connection, context)
    refute peer() == first
    assert length(HTTPFixture.requests(fixture)) == 4
  end

  test "closes a pending return if its worker dies after transfer", env do
    {connection, context, _fixture} = start_pool(env, size: 1)
    {:ok, key, _} = TLS.snapshot(connection)
    parent = self()
    deadline = System.monotonic_time(:millisecond) + @timeout

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        ConnectionPool.checkout(connection.pool, key, deadline, fn from, _, _, _ ->
          {:ok, socket} = Transport.open(connection, deadline)
          {:ok, socket, _} = Mint.HTTP.request(socket, "GET", "/1.0/hold", [], nil)
          opened = System.monotonic_time(:millisecond)
          assert {^socket, ^opened, _} = ConnectionPool.checkin(from, socket, opened, deadline)
          send(parent, {:return_pending, self()})

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive {:request, held, "GET", "/1.0/hold"}, @timeout
    assert_receive {:return_pending, ^worker}, @timeout
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout
    send(held, :check_closed)
    assert_receive {:closed, ^held}, @timeout
    assert {:ok, _} = query(connection, context)
    assert_receive {:request, _, "GET", "/1.0/probe"}, @timeout
  end

  test "cancellation and work scope termination discard a leased socket", env do
    {connection, context, _fixture} = start_pool(env, size: 1)

    for lifetime <- [:context, :scope] do
      assert {:ok, _} = query(connection, context)
      first = peer()
      request_context = RequestContext.new!(timeout: @timeout)
      request_connection = Connection.with_context(connection, request_context)
      scope = WorkScope.new(1)

      task =
        Task.async(fn ->
          if lifetime == :scope, do: WorkScope.bind(scope)
          query(request_connection, context, "GET", "/1.0/hold")
        end)

      assert_receive {:request, ^first, "GET", "/1.0/hold"}, @timeout
      stop_request(lifetime, request_context, scope)
      assert {:error, %Error{kind: kind}} = Task.await(task)
      WorkScope.close(scope)
      assert kind == if(lifetime == :context, do: :canceled, else: :request)
      send(first, :check_closed)
      assert_receive {:closed, ^first}, @timeout
    end
  end

  defp stop_request(:context, context, _), do: RequestContext.cancel(context)
  defp stop_request(:scope, _, scope), do: WorkScope.stop(scope)

  test "drops close responses, closes on owner loss and does not replay after dispatch", env do
    {connection, context, fixture} = start_pool(env, size: 1)
    assert {:ok, _} = query(connection, context, "GET", "/1.0/close")
    first = peer()
    assert {:ok, _} = query(connection, context)
    second = peer()
    refute second == first

    assert {:error, %Error{kind: :response_closed}} =
             query(connection, context, "GET", "/1.0/drop")

    assert peer() == second
    assert Enum.count(HTTPFixture.requests(fixture), &(&1.target == "/1.0/drop")) == 1

    owner = spawn(fn -> query(connection, context, "GET", "/1.0/hold") end)
    assert_receive {:request, held, "GET", "/1.0/hold"}, @timeout
    Process.exit(owner, :kill)
    send(held, :check_closed)
    assert_receive {:closed, ^held}, @timeout
    assert {:ok, _} = query(connection, context)
    refute peer() == held
  end

  test "expires idle bindings", env do
    {connection, context, _fixture} =
      start_pool(env, idle_timeout: 180, max_connection_age: 90, max_bindings: 1, size: 1)

    assert {:ok, _} = query(connection, context)
    first = peer()
    [binding] = Map.values(:sys.get_state(connection.pool).bindings)
    monitor = Process.monitor(binding)
    assert_receive {:DOWN, ^monitor, :process, ^binding, _}, @timeout
    assert {:ok, _} = query(connection, context)
    refute peer() == first
  end

  test "replaces an idle socket at the absolute age limit", env do
    {connection, context, _fixture} =
      start_pool(env, idle_timeout: @timeout, max_connection_age: 10, size: 1)

    assert {:ok, _} = query(connection, context)
    first = peer()
    monitor = Process.monitor(first)
    assert_receive {:DOWN, ^monitor, :process, ^first, _}, @timeout
    assert {:ok, _} = query(connection, context)
    refute peer() == first
  end

  test "a response over the current request budget is discarded", env do
    {connection, context, _fixture} = start_pool(env, size: 1)
    assert {:ok, _} = query(connection, context)
    first = peer()

    assert {:error, %Error{kind: :response_limit}} =
             query(%{connection | max_response_bytes: 1}, context)

    assert peer() == first
    assert {:ok, _} = query(connection, context)
    refute peer() == first
  end

  test "discards a socket with unsolicited data without replaying a dispatched read", env do
    {connection, context, fixture} = start_pool(env, size: 1)
    assert {:ok, _} = query(connection, context, "GET", "/1.0/stray")
    first = peer()
    send(first, :stray)
    assert_receive {:stray_sent, ^first}, @timeout
    # The peer's send can finish before the bytes reach the client's passive
    # TLS socket. The probe may discard it, or the response parser may reject
    # the bytes after dispatch. Neither outcome may send a second request.
    case query(connection, context) do
      {:ok, _} -> refute peer() == first
      {:error, %Error{kind: :response}} -> assert peer() == first
    end

    assert Enum.count(HTTPFixture.requests(fixture), &(&1.target == "/1.0/probe")) == 1
    assert {:ok, _} = query(connection, context)
    refute peer() == first
  end

  test "a reused socket honors the current request deadline", env do
    {connection, context, _fixture} = start_pool(env, size: 1)
    assert {:ok, _} = query(connection, context)
    first = peer()
    task = Task.async(fn -> query(%{connection | timeout: 200}, context, "GET", "/1.0/hold") end)
    assert_receive {:request, ^first, "GET", "/1.0/hold"}, @timeout
    assert {:error, %Error{kind: :deadline}} = Task.await(task)
    send(first, :check_closed)
    assert_receive {:closed, ^first}, @timeout
  end

  defp start_pool(env, opts \\ [], extra_cas \\ []) do
    %{identity: identity, root: root} = env
    pool = start_supervised!({ConnectionPool, opts})
    parent = self()
    ca_bundle = Path.join(root, "client-ca.pem")
    File.write!(ca_bundle, Enum.map([identity.cafile | extra_cas], &File.read!/1))

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: identity.certfile,
         keyfile: identity.keyfile,
         peer_options: [verify: :verify_peer, fail_if_no_peer_cert: true, cacertfile: ca_bundle],
         keep_alive: true,
         handler: fn request -> response(parent, request) end}
      )

    connection =
      Connection.https!(HTTPFixture.endpoint(fixture).url,
        owner: :test,
        pool: pool,
        tls: [
          cacertfile: identity.cafile,
          certfile: identity.certfile,
          keyfile: identity.keyfile
        ]
      )

    context = Context.new!(owner: :test, identity: :verified, ready?: fn -> true end)
    {connection, context, fixture}
  end

  defp response(parent, request) do
    send(parent, {:request, self(), request.method, request.target})

    case request.target do
      "/1.0/drop" -> %{upgrade: fn _, _ -> :ok end}
      "/1.0/close" -> %{raw: wire(request.method, "Connection: close\r\n")}
      "/1.0/hold" -> %{keep_alive: true, exchange: fn socket -> hold(parent, socket) end}
      "/1.0/stray" -> %{keep_alive: true, exchange: fn socket -> stray(parent, socket) end}
      _ -> %{keep_alive: true, exchange: fn socket -> normal(parent, socket, request.method) end}
    end
  end

  defp stray(parent, socket) do
    :ok = :ssl.send(socket, wire("GET"))

    receive do
      :stray ->
        :ok = :ssl.send(socket, "stray")
        send(parent, {:stray_sent, self()})
        :ok
    after
      @timeout -> {:error, :timeout}
    end
  end

  defp hold(parent, socket) do
    receive do
      :release ->
        :ssl.send(socket, wire("GET"))

      :check_closed ->
        assert {:error, :closed} = :ssl.recv(socket, 0, @timeout)
        send(parent, {:closed, self()})
        {:error, :closed}
    after
      @timeout -> {:error, :timeout}
    end
  end

  defp normal(parent, socket, method) do
    {:ok, cert} = :ssl.peercert(socket)
    send(parent, {:certificate, self(), cert})
    :ssl.send(socket, wire(method))
  end

  defp wire(method, headers \\ "") do
    body = if method == "HEAD", do: "", else: @response
    "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(@response)}\r\n#{headers}\r\n#{body}"
  end

  defp peer do
    assert_receive {:request, pid, _, _}, @timeout
    pid
  end

  defp query(connection, context, method \\ "GET", path \\ "/1.0/probe"),
    do: Incus.raw_query(connection, context, method, path, [])
end
