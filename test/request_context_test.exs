defmodule Opsmaru.Incus.RequestContextTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}

  alias Opsmaru.Incus.{
    Connection,
    Error,
    EventListener,
    Model,
    Operation,
    RawChannel,
    RequestContext,
    Server,
    Transfer,
    WebSocket
  }

  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture}
  @driver Path.expand("../.integration/request-context-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./requestcontext"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-ctx-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https], mode <- ["constructor", "with_context"] do
    test "#{transport} #{mode} native context preserves query, ETag and result", %{root: root} do
      compare(root, unquote(transport), unquote(mode))
    end
  end

  defp compare(root, transport, mode) do
    identity = if transport == :https, do: TLSIdentity.generate(root, "ctx", "localhost")

    fixture =
      fixture(root, identity, fn request ->
        if URI.parse(request.target).path == "/1.0", do: discovery(), else: profile()
      end)

    endpoint = HTTPFixture.endpoint(fixture)
    connection = connection(endpoint, identity)
    context = host_context()
    scope = RequestContext.new!(timeout: 3_000)

    input = %{
      Name: "fixture",
      Project: "project +",
      Member: "member +",
      Mode: mode,
      Timeout: 3_000
    }

    input =
      if identity,
        do:
          Map.merge(input, %{
            URL: endpoint.url,
            CA: File.read!(identity.cafile),
            Cert: File.read!(identity.certfile),
            Key: File.read!(identity.keyfile)
          }),
        else: Map.put(input, :Socket, endpoint.socket)

    expected = oracle(root, input)
    refute expected["error"], inspect(expected)
    [native] = HTTPFixture.requests(fixture)
    {:ok, original} = Incus.connect(connection, context)

    scoped =
      if mode == "constructor" do
        {:ok, value} = Incus.connect(connection, context, request_context: scope)
        value
      else
        Incus.with_context(original, scope)
      end

    {:ok, response} = Incus.call(scoped, "GetProfile", %{"name" => "fixture"})
    assert response.etag == expected["etag"]
    assert Model.encode(response.metadata) == expected["profile"]
    assert List.last(HTTPFixture.requests(fixture)).target == native.target
    assert response.connection == scoped.connection and response.identity == :verified
    assert original.connection.request_context == nil
    assert scoped.connection.request_context == scope
    refute inspect(scope) =~ root
  end

  test "native pre-cancellation rejects before I/O while the original client remains usable", %{
    root: root
  } do
    fixture = fixture(root, nil, fn _ -> profile() end)
    original = client(fixture)

    expected =
      oracle(root, %{
        Socket: HTTPFixture.endpoint(fixture).socket,
        Mode: "canceled",
        Timeout: 1_000,
        Name: "fixture"
      })

    assert expected["error"] =~ "context canceled"
    assert HTTPFixture.requests(fixture) == []
    scope = RequestContext.new!(timeout: 1_000)
    scoped = Incus.with_context(original, scope)
    assert :ok = RequestContext.cancel(scope)

    assert {:error, %Error{kind: :canceled}} =
             Incus.call(scoped, "GetProfile", %{"name" => "fixture"})

    assert HTTPFixture.requests(fixture) == []
    assert {:ok, _} = Incus.call(original, "GetProfile", %{"name" => "fixture"})
    assert length(HTTPFixture.requests(fixture)) == 1
  end

  test "expired context prevents dispatch and invalid configuration is passive", %{root: root} do
    fixture = fixture(root, nil, fn _ -> flunk("must not dispatch") end)
    scope = RequestContext.new!(timeout: 1)
    Process.sleep(5)
    assert RequestContext.status(scope) == :deadline

    assert {:error, %Error{kind: :deadline}} =
             Incus.call(Incus.with_context(client(fixture), scope), "GetProfile", %{
               "name" => "fixture"
             })

    assert HTTPFixture.requests(fixture) == []

    for opts <- [
          [],
          [timeout: 0],
          [timeout: 3_600_001],
          [timeout: 1, timeout: 2],
          [timeout: 1, owner: :not_pid]
        ] do
      assert_raise ArgumentError, fn -> RequestContext.new!(opts) end
    end

    assert_raise ArgumentError, fn -> Incus.with_context(client(fixture), %{timeout: 1}) end
  end

  for method <- ["GET", "POST"] do
    test "canceling a dispatched #{method} closes the socket and preserves mutation uncertainty",
         %{root: root} do
      assert_dispatched_cancellation(root, unquote(method))
    end
  end

  defp assert_dispatched_cancellation(root, method) do
    parent = self()

    fixture =
      fixture(root, nil, fn _ ->
        %{
          upgrade: fn transport, socket ->
            send(parent, {:entered, self()})
            result = transport.recv(socket, 0, 1_000)
            send(parent, {:closed, result})
          end
        }
      end)

    scope = RequestContext.new!(timeout: 3_000)
    scoped = Incus.with_context(client(fixture), scope)

    task =
      Task.async(fn ->
        if method == "GET",
          do: Incus.call(scoped, "GetProfile", %{"name" => "fixture"}),
          else:
            Incus.call(scoped, "CreateProfile", %{},
              body: %{"name" => "fixture", "config" => %{}, "devices" => %{}}
            )
      end)

    assert_receive {:entered, _}, 1_000
    assert :ok = RequestContext.cancel(scope)
    expected = if method == "GET", do: :canceled, else: :uncertain
    assert {:error, %Error{kind: ^expected}} = Task.await(task, 500)
    assert_receive {:closed, {:error, :closed}}, 1_000
    assert [%{method: ^method}] = HTTPFixture.requests(fixture)
  end

  test "absolute deadline closes blocked I/O with native read deadline semantics", %{root: root} do
    parent = self()

    fixture =
      fixture(root, nil, fn _ ->
        %{
          upgrade: fn transport, socket ->
            send(parent, :entered)
            send(parent, {:closed, transport.recv(socket, 0, 1_000)})
          end
        }
      end)

    expected =
      oracle(root, %{
        Socket: HTTPFixture.endpoint(fixture).socket,
        Mode: "constructor",
        Timeout: 100,
        Name: "fixture"
      })

    assert expected["error"] =~ "context deadline exceeded"
    assert_receive :entered, 500
    assert_receive {:closed, {:error, :closed}}, 1_000
    scope = RequestContext.new!(timeout: 100)

    task =
      Task.async(fn ->
        Incus.call(Incus.with_context(client(fixture), scope), "GetProfile", %{
          "name" => "fixture"
        })
      end)

    assert_receive :entered, 500
    assert {:error, %Error{kind: :deadline}} = Task.await(task, 500)
    assert_receive {:closed, {:error, :closed}}, 1_000
    assert length(HTTPFixture.requests(fixture)) == 2
  end

  test "scope owner loss terminates in-flight I/O even when the calling process survives", %{
    root: root
  } do
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:scope, RequestContext.new!(timeout: 3_000)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:scope, scope}

    fixture =
      fixture(root, nil, fn _ ->
        %{
          upgrade: fn transport, socket ->
            send(parent, :entered)
            send(parent, {:closed, transport.recv(socket, 0, 1_000)})
          end
        }
      end)

    task =
      Task.async(fn ->
        Incus.call(Incus.with_context(client(fixture), scope), "GetProfile", %{
          "name" => "fixture"
        })
      end)

    assert_receive :entered, 500
    send(owner, :stop)
    assert {:error, %Error{kind: :canceled}} = Task.await(task, 500)
    assert_receive {:closed, {:error, :closed}}, 1_000
  end

  test "context cancellation kills an exit-trapping binary sink", %{root: root} do
    parent = self()

    fixture =
      fixture(root, nil, fn _ ->
        %{raw: "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n" <> <<0, 255, 128>>}
      end)

    scope = RequestContext.new!(timeout: 3_000)

    sink = fn _ ->
      Process.flag(:trap_exit, true)
      send(parent, {:sink, self()})

      receive do
        :never -> :ok
      end
    end

    task =
      Task.async(fn ->
        Transfer.download(Incus.with_context(client(fixture), scope), "/1.0/opaque", sink)
      end)

    assert_receive {:sink, pid}, 1_000
    monitor = Process.monitor(pid)
    RequestContext.cancel(scope)
    assert {:error, %Error{kind: :canceled}} = Task.await(task, 500)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 500
  end

  test "canceling a channel context closes only its local channel without backend cancellation",
       %{root: root} do
    fixture =
      start_supervised!({WebSocketFixture, path: Path.join(root, "ws.sock"), wire: ""})

    original = %Incus{
      connection: Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture),
      context: host_context(),
      server: %Server{}
    }

    scope = RequestContext.new!(timeout: 3_000)
    scoped = Incus.with_context(original, scope)
    {:ok, channel} = WebSocket.open(scoped, "/1.0/events")
    monitor = Process.monitor(channel.pid)
    RequestContext.cancel(scope)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 500
    assert original.connection.request_context == nil
    assert Enum.all?(WebSocketFixture.requests(fixture), &(&1.method == "GET"))
  end

  test "local operation wait cancellation preserves the accepted snapshot and never sends DELETE",
       %{root: root} do
    fixture =
      fixture(root, nil, fn _ ->
        %{status: 200, body: %{type: "sync", metadata: %{id: "op", status_code: 103}}}
      end)

    original = client(fixture)

    accepted = %Opsmaru.Incus.Response{
      type: "async",
      operation: "/1.0/operations/op",
      metadata: %{"id" => "op", "status_code" => 103},
      connection: original.connection,
      identity: :verified
    }

    {:ok, operation} = Operation.from_response(original, accepted)
    scope = RequestContext.new!(timeout: 1_000)
    RequestContext.cancel(scope)

    assert {:error, %Error{kind: :canceled, operation: "/1.0/operations/op", response: ^accepted}} =
             Operation.wait_with_context(operation, scope)

    assert HTTPFixture.requests(fixture) == []
    assert {:ok, snapshot} = Operation.get(operation)
    assert snapshot.data == accepted.metadata
    assert {:ok, refreshed} = Operation.refresh(operation)
    assert refreshed.url == operation.url and refreshed.client == original
    assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))
  end

  test "terminal context reason survives later cancellation or deadline" do
    expired = RequestContext.new!(timeout: 1)
    Process.sleep(5)
    assert :ok = RequestContext.cancel(expired)
    assert RequestContext.status(expired) == :deadline
    canceled = RequestContext.new!(timeout: 100)
    RequestContext.cancel(canceled)
    Process.sleep(150)
    assert RequestContext.status(canceled) == :canceled
  end

  test "canceling during a long poll interval returns promptly and retains the latest native snapshot",
       %{root: root} do
    parent = self()

    fixture =
      fixture(root, nil, fn _ ->
        send(parent, :polled)
        %{status: 200, body: %{type: "sync", metadata: %{id: "op", status_code: 103}}}
      end)

    original = client(fixture)

    accepted = %Opsmaru.Incus.Response{
      type: "async",
      operation: "/1.0/operations/op",
      metadata: %{"id" => "op", "status_code" => 103},
      connection: original.connection,
      identity: :verified
    }

    {:ok, operation} = Operation.from_response(original, accepted)
    scope = RequestContext.new!(timeout: 3_000)

    task =
      Task.async(fn ->
        Operation.wait_with_context(operation, scope, timeout: 10_000, poll_interval: 60_000)
      end)

    assert_receive :polled, 500
    Process.sleep(20)
    RequestContext.cancel(scope)

    assert {:error, %Error{kind: :canceled, operation: "/1.0/operations/op", response: latest}} =
             Task.await(task, 500)

    assert latest.metadata.data["id"] == "op"
    assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))
  end

  test "context cancellation releases an event listener and its exit-trapping callback", %{
    root: root
  } do
    parent = self()
    event = Jason.encode!(%{type: "operation", metadata: %{id: "op", status_code: 103}})

    fixture =
      start_supervised!(
        {WebSocketFixture,
         path: Path.join(root, "event.sock"),
         wire: "",
         response_frames: fn _, _ -> WebSocketFixture.frame(1, event) end}
      )

    original = %Incus{
      connection: Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture),
      context: host_context(),
      server: %Server{}
    }

    scope = RequestContext.new!(timeout: 3_000)

    {:ok, listener} =
      EventListener.open(Incus.with_context(original, scope), types: ["operation"])

    assert {:ok, _} =
             EventListener.add_handler(listener, ["operation"], fn _ ->
               Process.flag(:trap_exit, true)
               send(parent, {:callback, self()})

               receive do
                 :never -> :ok
               end
             end)

    assert :ok = EventListener.send_event(listener, %{"type" => "logging", "metadata" => %{}})
    assert_receive {:callback, pid}, 1_000
    callback = Process.monitor(pid)
    monitor = Process.monitor(listener.pid)
    RequestContext.cancel(scope)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 500
    assert_receive {:DOWN, ^callback, :process, _, :killed}, 500
    assert Enum.all?(WebSocketFixture.requests(fixture), &(&1.method == "GET"))
  end

  test "raw native upgrade channels obey the local context without backend DELETE", %{root: root} do
    parent = self()

    fixture =
      fixture(root, nil, fn _ ->
        %{
          upgrade: fn transport, socket ->
            :ok =
              transport.send(
                socket,
                "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: sftp\r\n\r\n" <>
                  <<0, 255, 128>>
              )

            send(parent, {:closed, transport.recv(socket, 0, 1_000)})
          end
        }
      end)

    scope = RequestContext.new!(timeout: 3_000)
    {:ok, channel} = Incus.sftp(Incus.with_context(client(fixture), scope), "fixture")
    assert {:ok, <<0, 255, 128>>} = RawChannel.recv(channel)
    monitor = Process.monitor(channel.pid)
    RequestContext.cancel(scope)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 500
    assert_receive {:closed, {:error, :closed}}, 1_000
    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  test "native client disconnect does not cancel contexts or hide accepted operations", %{
    root: root
  } do
    fixture = fixture(root, nil, fn _ -> profile() end)
    original = client(fixture)
    scope = RequestContext.new!(timeout: 1_000)
    scoped = Incus.with_context(original, scope)
    assert :ok = Incus.disconnect(scoped)
    assert RequestContext.status(scope) == :active
    assert {:ok, _} = Incus.call(scoped, "GetProfile", %{"name" => "fixture"})
    assert original.connection.request_context == nil
  end

  defp host_context,
    do: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)

  defp client(fixture),
    do: %Incus{
      connection: connection(HTTPFixture.endpoint(fixture), nil),
      context: host_context(),
      server: %Server{}
    }

  defp connection(endpoint, nil),
    do:
      Connection.unix!(endpoint.socket, owner: :fixture, project: "project +", member: "member +")

  defp connection(endpoint, identity),
    do:
      Connection.https!(endpoint.url,
        owner: :fixture,
        project: "project +",
        member: "member +",
        tls: [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
      )

  defp fixture(root, identity, handler) do
    opts =
      if identity,
        do: [transport: :ssl, certfile: identity.certfile, keyfile: identity.keyfile],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "s-#{System.unique_integer([:positive])}")
        ]

    start_supervised!({HTTPFixture, opts ++ [handler: handler]}, id: make_ref())
  end

  defp profile,
    do: %{
      status: 200,
      headers: [{"etag", "\"native-scope\""}],
      body: %{
        type: "sync",
        metadata: %{
          name: "fixture",
          config: %{},
          devices: %{},
          description: "scope",
          used_by: [],
          project: ""
        }
      }
    }

  defp discovery,
    do: %{
      status: 200,
      body: %{type: "sync", metadata: %{api_version: "1.0", api_extensions: [], auth: "trusted"}}
    }

  defp oracle(root, input) do
    path = Path.join(root, "oracle.json")
    File.write!(path, Jason.encode!(input))

    {out, status} =
      System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "oracle", @driver, path],
        stderr_to_stdout: true
      )

    assert status == 0, out
    Jason.decode!(out)
  end
end
