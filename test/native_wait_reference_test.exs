defmodule Opsmaru.Incus.NativeWaitReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Model, RequestContext, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}
  @driver Path.expand("../.integration/native-wait-driver", __DIR__)
  @uuid "01234567-89ab-cdef-0123-456789abcdef"
  @secret "0123456789abcdef0123456789abcdef"

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-wait-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} native wait gated snapshots, errors and EOF agree with the pinned client",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for method <- ["GetOperationWait", "GetOperationWaitSecret"],
          outcome <- [103, 200, 400, 401, :forbidden, :not_found, :eof, :reset] do
        compare(root, identity, method, outcome)
      end
    end

    test "#{transport} native wait stalled body obeys deadline, cancellation and caller loss", %{
      root: root
    } do
      identity = identity(root, unquote(transport))

      for method <- ["GetOperationWait", "GetOperationWaitSecret"],
          mode <- [:deadline, :cancel, :caller_loss] do
        parent = self()
        tag = make_ref()
        fixture = backend(root, identity, fn _ -> gated(parent, tag, response(200), :closed) end)
        original = client(fixture, identity)
        scope = RequestContext.new!(timeout: if(mode == :deadline, do: 3_000, else: 30_000))
        scoped = Incus.with_context(original, scope)

        {pid, monitor} =
          spawn_monitor(fn ->
            send(parent, {tag, Incus.call(scoped, method, args(method, 30))})
          end)

        assert_receive {^tag, :entered, _peer}, 10_000

        case mode do
          :deadline -> :ok
          :cancel -> RequestContext.cancel(scope)
          :caller_loss -> Process.exit(pid, :kill)
        end

        if mode == :caller_loss do
          assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 10_000
        else
          kind = if mode == :deadline, do: :deadline, else: :canceled
          assert_receive {^tag, {:error, %Error{kind: ^kind} = error}}, 10_000
          refute inspect(error) =~ @secret
          assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 10_000
        end

        assert_receive {^tag, :closed, {:error, :closed}}, 10_000
        assert original.connection.request_context == nil
        assert scoped.connection.request_context == scope
        assert [%{method: "GET"} = request] = HTTPFixture.requests(fixture)
        assert URI.parse(request.target).path == "/1.0/operations/#{@uuid}/wait"
        assert URI.decode_query(URI.parse(request.target).query)["timeout"] == "30"
      end
    end

    test "#{transport} native wait rejects unbounded timeout and pre-canceled contexts before I/O",
         %{root: root} do
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> response(200) end)
      original = client(fixture, identity)
      scope = RequestContext.new!(timeout: 30_000)
      RequestContext.cancel(scope)

      for method <- ["GetOperationWait", "GetOperationWaitSecret"],
          timeout <- [-1, 3601, "1", 1.0] do
        assert {:error, %Error{kind: :invalid_arguments}} =
                 Incus.call(original, method, args(method, timeout))
      end

      # Empty and arbitrary secrets are approved exclusions, never a plain wait.
      for secret <- ["", "ABCDEF", "not-hex", "a b", "0123%2f", String.duplicate("a", 1025)] do
        assert {:error, %Error{kind: :invalid_arguments}} =
                 Incus.call(
                   original,
                   "GetOperationWaitSecret",
                   %{args("GetOperationWaitSecret", 0) | "secret" => secret}
                 )
      end

      for method <- ["GetOperationWait", "GetOperationWaitSecret"] do
        assert {:error, %Error{kind: :canceled}} =
                 Incus.call(Incus.with_context(original, scope), method, args(method, 0))
      end

      assert HTTPFixture.requests(fixture) == []

      for method <- ["GetOperationWait", "GetOperationWaitSecret"] do
        assert {:ok, _} = Incus.call(original, method, args(method, 3600))
      end

      assert [first, second] = HTTPFixture.requests(fixture)

      assert Enum.map([first, second], &URI.decode_query(URI.parse(&1.target).query)) == [
               %{"project" => "fixture scope", "target" => "member/a", "timeout" => "3600"},
               %{
                 "project" => "fixture scope",
                 "target" => "member/a",
                 "timeout" => "3600",
                 "secret" => @secret
               }
             ]
    end
  end

  defp compare(root, identity, method, outcome) do
    parent = self()
    tag = make_ref()

    handler =
      if outcome == :reset,
        do: fn _ -> reset(parent, tag) end,
        else: fn _ -> gated(parent, tag, response(outcome), :release) end

    timeout = if outcome == 103, do: 0, else: 1
    native = backend(root, identity, handler)

    input =
      Map.merge(native_connection(native, identity), %{
        action: method,
        args: Enum.map(params(method), &args(method, timeout)[&1]),
        project: "fixture scope",
        target: "member/a"
      })

    file = Path.join(root, "oracle.json")
    File.write!(file, Jason.encode!(input))
    task = Task.async(fn -> System.cmd(@driver, [file], stderr_to_stdout: true) end)
    release(task, tag, outcome)
    {out, status} = Task.await(task, 10_000)
    assert status == 0, out
    expected = Jason.decode!(out)
    fixture = backend(root, identity, handler)
    client = client(fixture, identity)
    task = Task.async(fn -> Incus.call(client, method, args(method, timeout)) end)
    release(task, tag, outcome)
    actual = Task.await(task, 10_000)

    assert WireComparison.request(List.last(HTTPFixture.requests(native))) ==
             WireComparison.request(List.last(HTTPFixture.requests(fixture)))

    assert length(HTTPFixture.requests(native)) == 2
    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)

    case outcome do
      :eof ->
        assert expected["error"]
        assert {:error, %Error{kind: :response}} = actual

      :reset ->
        assert expected["error"]
        assert {:error, %Error{kind: :response} = error} = actual
        refute inspect(error) =~ @secret

      native when native in [:forbidden, :not_found] ->
        status = if native == :forbidden, do: 403, else: 404

        assert {:error,
                %Error{
                  kind: :native,
                  http_status: ^status,
                  error_code: ^status,
                  message: message,
                  response: reply
                } = error} = actual

        assert expected["error_status"] == status
        assert expected["error"] == message
        assert reply.connection == client.connection and reply.identity == :verified
        refute inspect(error) =~ @secret

      code ->
        refute expected["error"]
        assert {:ok, reply} = actual
        assert %Model{type: "Operation", data: data} = reply.metadata
        assert Map.take(hd(expected["outputs"]), Map.keys(data)) == data
        assert data["id"] == @uuid and data["status_code"] == code
        assert reply.etag == Enum.at(expected["outputs"], 1)
        assert reply.connection == client.connection and reply.identity == :verified
        refute inspect(reply) =~ @secret
    end
  end

  defp release(_task, tag, :reset), do: assert_receive({^tag, :entered, _}, 10_000)

  defp release(task, tag, outcome) do
    assert_receive {^tag, :entered, peer}, 10_000
    assert Task.yield(task, 0) == nil
    send(peer, if(outcome == :eof, do: :eof, else: :release))
  end

  # Incus flushes headers before op.Wait; the fixture holds the declared body.
  defp gated(parent, tag, response, action) do
    body = Jason.encode!(response.body)

    %{
      upgrade: fn transport, socket ->
        :ok =
          transport.send(
            socket,
            "HTTP/1.1 #{response.status} Fixture\r\nContent-Type: application/json\r\nETag: \"wait-etag\"\r\nContent-Length: #{byte_size(body)}\r\nConnection: keep-alive\r\n\r\n"
          )

        send(parent, {tag, :entered, self()})

        case action do
          :closed ->
            send(parent, {tag, :closed, transport.recv(socket, 0, 30_000)})

          :release ->
            receive do
              :release -> :ok = transport.send(socket, body)
              :eof -> :ok
            after
              30_000 -> flunk("wait fixture was not released")
            end
        end
      end
    }
  end

  # The connection drops after the request is read and before any response header.
  defp reset(parent, tag) do
    %{upgrade: fn _transport, _socket -> send(parent, {tag, :entered, self()}) end}
  end

  defp response(:eof), do: response(200)

  defp response(:not_found),
    do: %{status: 404, body: %{type: "error", error_code: 404, error: "Operation not found"}}

  defp response(:forbidden),
    do: %{status: 403, body: %{type: "error", error_code: 403, error: "denied #{@secret}"}}

  defp response(code),
    do: %{
      status: 200,
      body: %{
        type: "sync",
        status_code: 200,
        metadata: %{
          id: @uuid,
          status_code: code,
          status:
            %{103 => "Running", 200 => "Success", 400 => "Failure", 401 => "Cancelled"}[code],
          err: %{400 => "exec failed", 401 => "operation canceled"}[code] || "",
          may_cancel: false,
          metadata: %{}
        }
      }
    }

  defp params("GetOperationWait"), do: ["uuid", "timeout"]
  defp params("GetOperationWaitSecret"), do: ["uuid", "secret", "timeout"]

  defp args(method, timeout),
    do: Map.take(%{"uuid" => @uuid, "secret" => @secret, "timeout" => timeout}, params(method))

  defp identity(_root, :unix), do: nil
  defp identity(root, :https), do: TLSIdentity.generate(root, "wait", "localhost")

  defp backend(root, identity, handler) do
    options =
      if identity,
        do: [
          transport: :ssl,
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            cacertfile: identity.cafile,
            verify: :verify_peer,
            fail_if_no_peer_cert: true
          ]
        ],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "s#{System.unique_integer([:positive])}")
        ]

    start_supervised!(
      {HTTPFixture,
       options ++
         [
           handler: fn request ->
             if URI.parse(request.target).path == "/1.0",
               do: %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{api_version: "1.0", api_extensions: [], environment: %{}}
                 }
               },
               else: handler.(request)
           end
         ]},
      id: make_ref()
    )
  end

  defp client(fixture, identity) do
    endpoint = HTTPFixture.endpoint(fixture)
    options = [owner: :fixture, project: "fixture scope", member: "member/a", timeout: 30_000]

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            options ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, options)

    %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: []}
    }
  end

  defp native_connection(fixture, nil), do: %{socket: HTTPFixture.endpoint(fixture).socket}

  defp native_connection(fixture, identity),
    do: %{
      url: HTTPFixture.endpoint(fixture).url,
      server_cert: File.read!(identity.certfile),
      tls_ca: File.read!(identity.cafile),
      client_cert: File.read!(identity.certfile),
      client_key: File.read!(identity.keyfile)
    }
end
