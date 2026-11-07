defmodule Opsmaru.Incus.GatewayFixtureClientTest do
  use Opsmaru.TestSupport.GatewayCase, async: false
  alias Opsmaru.TestSupport.HTTPFixture

  test "bodyless TLS denial needs no write after the peer closes", context do
    {fixture, port, tls} = tls_fixture(context)
    {:ssl, socket} = client = RawHTTP.connect(port, tls)
    RawHTTP.send!(client, RawHTTP.head("GET", "/denied", [{"connection", "close"}]))
    response = socket |> tls_until_closed("") |> RawHTTP.parse()
    assert response.status == 403
    assert response.complete
    # The old helper's redundant empty-body write fails even though a complete
    # denial response has already arrived. No policy or TLS deadline expired.
    assert {:error, :closed} = :ssl.send(socket, "")

    for body <- ["", []] do
      {response, writes} = traced_request(port, "GET", body, tls)
      assert response.status == 403
      assert response.complete
      assert length(writes) == 1
      refute Enum.any?(writes, &(IO.iodata_length(&1) == 0))
    end

    assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET" and &1.body == ""))
  end

  test "TLS request helper retains nonempty binary bodies", context do
    {fixture, port, tls} = tls_fixture(context)
    body = :binary.copy(<<0, 255, 128, 42>>, 8_192)
    {response, writes} = traced_request(port, "POST", body, tls)
    assert response.status == 403
    assert response.complete
    refute Enum.any?(writes, &(IO.iodata_length(&1) == 0))
    assert [%{method: "POST", body: ^body}] = HTTPFixture.requests(fixture)
  end

  defp tls_until_closed(socket, bytes) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, next} -> tls_until_closed(socket, bytes <> next)
      {:error, :closed} -> bytes
    end
  end

  defp tls_fixture(context) do
    server = TLSIdentity.generate(context.root, "raw-client-server", "localhost")

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: server.certfile,
         keyfile: server.keyfile,
         handler: fn _ -> %{status: 403, body: %{error: "fixture denial"}} end}
      )

    port = URI.parse(HTTPFixture.endpoint(fixture).url).port
    {fixture, port, [verify: :verify_peer, cacertfile: server.cafile]}
  end

  defp traced_request(port, method, body, tls) do
    observer = self()

    worker =
      spawn(fn ->
        receive do
          :go ->
            response = RawHTTP.request(port, method, "/denied", [], body, tls)
            send(observer, {:response, self(), response})

            receive do
              :stop -> :ok
            end
        end
      end)

    on_exit(fn ->
      Process.exit(worker, :kill)
      :erlang.trace_pattern({:ssl, :send, 2}, false, [])
    end)

    :erlang.trace_pattern({:ssl, :send, 2}, true, [])
    :erlang.trace(worker, true, [:call, {:tracer, self()}])

    try do
      send(worker, :go)
      assert_receive {:response, ^worker, response}, 5_000
      :erlang.trace(worker, false, [:call])
      delivered = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, ^worker, ^delivered}, 1_000
      {response, ssl_writes(worker, [])}
    after
      :erlang.trace_pattern({:ssl, :send, 2}, false, [])
      send(worker, :stop)
    end
  end

  defp ssl_writes(worker, writes) do
    receive do
      {:trace, ^worker, :call, {:ssl, :send, [_socket, bytes]}} ->
        ssl_writes(worker, [bytes | writes])
    after
      0 -> Enum.reverse(writes)
    end
  end
end
