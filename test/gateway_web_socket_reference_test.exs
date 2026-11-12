defmodule Opsmaru.Incus.GatewayWebSocketReferenceTest do
  use Opsmaru.TestSupport.GatewayCase, async: false
  alias Opsmaru.TestSupport.{HTTPFixture, NativeWebSocketBackend}
  @reference Path.expand("reference", __DIR__)
  @drivers ~w(execio console eventhandlers directwebsocket)
  @extensions ~w(instances console)

  setup_all do
    assert Jason.decode!(File.read!(Path.expand("../priv/incus/reference.json", __DIR__)))[
             "revision"
           ] == "13f3992766142d5087fff2e362cd2e1a75294fe8"

    for name <- @drivers do
      driver = Path.expand("../.integration/gateway-ws-#{name}", __DIR__)
      File.mkdir_p!(Path.dirname(driver))

      {out, code} =
        System.cmd("mise", ["exec", "--", "go", "build", "-o", driver, "./#{name}"],
          cd: @reference,
          stderr_to_stdout: true,
          env: [{"GOTOOLCHAIN", "local"}]
        )

      assert code == 0, out
    end

    :ok
  end

  test "pinned native exec IO and authoritative exit status agree directly and through mutual TLS gateway",
       context do
    for mode <- [:exec, :interactive] do
      fixture = NativeWebSocketBackend.start(context, mode)
      {credentials, _} = mounted(context, fixture)

      input = %{
        Project: "allowed",
        Member: "member-a",
        Stdin: Base.encode64(<<255, 0, 42>>),
        Mode: if(mode == :interactive, do: "interactive", else: "collect"),
        Body: %{
          "command" => ["fixture"],
          "wait-for-websocket" => true,
          "interactive" => mode == :interactive
        }
      }

      direct =
        run(context, "execio", Map.put(input, :Socket, HTTPFixture.endpoint(fixture).socket))

      gateway = run(context, "execio", Map.merge(input, credentials))
      assert gateway == direct
      refute gateway["error"]
      assert gateway["operation"]["id"] == "native"
      assert gateway["operation"]["metadata"]["return"] == 7
      assert Base.decode64!(gateway["stdout"]) == <<0, 255, 128, 10>>
      if mode == :exec, do: assert(Base.decode64!(gateway["stderr"]) == <<254, 0, 13>>)
      posts = Enum.filter(HTTPFixture.requests(fixture), &(&1.method == "POST"))
      assert length(posts) == 2

      assert Enum.all?(
               posts,
               &(&1.target == "/1.0/instances/fixture/exec?project=allowed&target=member-a")
             )

      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))

      if mode == :interactive do
        assert_receive {:native_frame, "control", :text, resize}, 1_000
        assert Jason.decode!(resize)["command"] == "window-resize"
        assert_receive {:native_frame, "control", :text, signal}, 1_000
        assert Jason.decode!(signal)["signal"] == 15
      end
    end
  end

  test "pinned native static and dynamic console data and resize agree through gateway",
       context do
    for mode <- ["static", "dynamic"] do
      fixture = NativeWebSocketBackend.start(context, :console)
      {credentials, _} = mounted(context, fixture)

      input = %{
        mode: mode,
        payload: Base.encode64(<<255, 0, 128, 42>>),
        expect: 7,
        attachments: 1,
        body: %{width: 80, height: 24}
      }

      direct =
        run(context, "console", Map.put(input, :socket, HTTPFixture.endpoint(fixture).socket))

      gateway = run(context, "console", Map.merge(input, lowercase(credentials)))
      assert gateway == direct
      refute gateway["error"]
      assert gateway["operation"]["id"] == "native"
      assert Enum.map(gateway["outputs"], &Base.decode64!/1) == [<<0, 255, 128, 255, 0, 128, 42>>]
      assert_receive {:native_frame, "control", :text, resize}, 1_000
      assert Jason.decode!(resize)["command"] == "window-resize"
      assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 2
    end
  end

  test "pinned native event listener lifecycle and generic operation upgrade work through gateway",
       context do
    fixture = NativeWebSocketBackend.start(context, :events)
    {credentials, _} = mounted(context, fixture)

    event = %{
      type: "logging",
      timestamp: "2026-11-07T00:00:00Z",
      metadata: %{message: "native event"}
    }

    result = run(context, "eventhandlers", Map.put(lowercase(credentials), :event, event))
    assert result["event"]["metadata"]["message"] == "native event"
    assert result["active_before"] and not result["active_after"]
    assert result["wait"] and result["wait_again"]

    result =
      run(
        context,
        "directwebsocket",
        Map.merge(lowercase(credentials), %{
          path: "/1.0/operations/native/websocket?secret=operation"
        })
      )

    assert result["status"] == 101
    assert result["kind"] == 2
    assert Base.decode64!(result["body"]) == <<0, 255, 128>>
    requests = HTTPFixture.requests(fixture)
    assert Enum.any?(requests, &String.starts_with?(&1.target, "/1.0/events"))
    refute Enum.any?(requests, &(&1.method == "DELETE"))
  end

  test "accepted console POST is not replayed when a later channel handshake fails", context do
    fixture = NativeWebSocketBackend.start(context, :partial_console)
    {credentials, _} = mounted(context, fixture)

    result =
      run(
        context,
        "console",
        Map.merge(lowercase(credentials), %{mode: "static", payload: "", expect: 0, body: %{}})
      )

    assert result["error"] =~ "native channel rejected"
    requests = HTTPFixture.requests(fixture)
    assert Enum.count(requests, &(&1.method == "POST")) == 1
    refute Enum.any?(requests, &(&1.method == "DELETE"))
    assert Enum.any?(requests, &String.contains?(&1.target, "secret=0"))
  end

  defp mounted(context, fixture) do
    server =
      TLSIdentity.generate(
        context.root,
        "front-#{System.unique_integer([:positive])}",
        "localhost"
      )

    client =
      TLSIdentity.generate(context.root, "caller-#{System.unique_integer([:positive])}", "caller")

    {ref, port} = GatewayServer.start_https(server, client.cafile)
    on_exit(fn -> GatewayServer.stop(ref) end)
    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture)

    mount(context, connection,
      host_config: %{
        authorize: fn request ->
          if request.peer.certificate == client.der,
            do: {:ok, :verified},
            else: {:error, :unauthenticated}
        end,
        identity: %{
          origin: "https://gateway.example.com:#{port}",
          addresses: ["gateway.example.com:#{port}"],
          certificate: File.read!(server.certfile),
          connection: connection,
          api_extensions: @extensions
        }
      }
    )

    {%{
       URL: "https://localhost:#{port}",
       CA: File.read!(server.cafile),
       Cert: File.read!(client.certfile),
       Key: File.read!(client.keyfile),
       ServerCert: File.read!(server.certfile)
     }, port}
  end

  defp lowercase(credentials),
    do: %{
      url: credentials[:URL],
      tls_ca: credentials[:CA],
      server_cert: credentials[:ServerCert],
      client_cert: credentials[:Cert],
      client_key: credentials[:Key],
      ca: credentials[:CA],
      cert: credentials[:Cert],
      key: credentials[:Key]
    }

  defp run(context, name, input) do
    file = Path.join(context.root, "input-#{System.unique_integer([:positive])}.json")
    File.write!(file, Jason.encode!(input))
    File.chmod!(file, 0o600)
    driver = Path.expand("../.integration/gateway-ws-#{name}", __DIR__)

    {output, code} =
      System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "gateway-ws-fixture", driver, file],
        stderr_to_stdout: true
      )

    assert code == 0, output
    Jason.decode!(output)
  end
end
