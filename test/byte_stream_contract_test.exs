defmodule Opsmaru.Incus.ByteStreamContractTest do
  @moduledoc """
  S07 auxiliary byte stream contracts on Unix and mutual TLS, compared with the
  pinned client's unchanged typed stream methods through the streams driver.
  """
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, RequestContext, Response, Server, Streams}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  @reference_dir Path.expand("reference", __DIR__)
  @extensions ["metrics", "network_acl_log", "console", "container_edit_metadata"]
  @payload :binary.copy(<<0, 255, 128, 13, 10, 0, 97>>, 3_000)
  # Every S07 download, with host routing and its exact selectors.
  @downloads [
    %{action: "GetMetrics", path: "/1.0/metrics"},
    %{action: "GetNetworkACLLogfile", name: "acl one", path: "/1.0/network-acls/acl%20one/log"},
    %{
      action: "GetInstanceLogfile",
      name: "vm one",
      filename: "server.log",
      path: "/1.0/instances/vm%20one/logs/server.log"
    },
    %{action: "GetInstanceConsoleLog", name: "vm one", path: "/1.0/instances/vm%20one/console"},
    %{
      action: "GetInstanceTemplateFile",
      name: "ctr one",
      template: "a b/c=d&f",
      path: "/1.0/instances/ctr%20one/metadata/templates",
      query: %{"path" => "a b/c=d&f"}
    },
    %{
      action: "GetInstanceDebugMemory",
      name: "vm one",
      format: "v2",
      path: "/1.0/instances/vm%20one/debug/memory",
      query: %{"format" => "v2", "instance-type" => "virtual-machine"}
    }
  ]

  setup_all do
    driver = Path.join(System.tmp_dir!(), "op-s07-driver-#{System.unique_integer([:positive])}")

    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", driver, "./streams"],
        cd: @reference_dir,
        stderr_to_stdout: true,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    assert status == 0, output
    on_exit(fn -> File.rm(driver) end)
    %{driver: driver}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-s07-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} S07 downloads agree with the pinned client on request, selectors, routing and bytes",
         %{driver: driver, root: root} do
      identity = identity(root, unquote(transport))

      for scenario <- @downloads do
        payload = payload(scenario)
        fixture = backend(root, identity, fn _ -> bytes(payload) end)
        go = run_go(driver, input(fixture, identity, scenario))
        assert go["error"] == nil

        {elixir, result} = with_sink(&download(client(fixture, identity), scenario, &1))
        size = byte_size(payload)
        assert {:ok, %Opsmaru.Incus.Transfer{bytes: ^size}} = result
        assert elixir == payload and elixir == Base.decode64!(go["bytes"])

        # The pinned client first, then ours: same path, selectors and routing.
        assert [native, local] = HTTPFixture.requests(fixture)
        assert signature(native) == signature(local)
        assert URI.parse(local.target).path == scenario.path and local.method == "GET"

        assert Map.drop(signature(local)["query"], ~w(project target)) ==
                 Map.get(scenario, :query, %{})
      end
    end

    test "#{transport} S07 template upload agrees with the pinned client on body bytes and headers",
         %{driver: driver, root: root} do
      identity = identity(root, unquote(transport))
      payload = :binary.copy(<<0, 254, 7>>, 20_000)

      fixture =
        backend(root, identity, fn _ ->
          %{
            status: 200,
            headers: %{"ETag" => "tpl"},
            body: %{type: "sync", status_code: 200, metadata: %{}}
          }
        end)

      scenario = %{action: "CreateInstanceTemplateFile", name: "ctr one", template: "path x"}
      go = run_go(driver, Map.put(input(fixture, identity, scenario), "payload", payload))
      assert go["error"] == nil

      assert {:ok, %Response{type: "sync", etag: "tpl"}} =
               Streams.create_instance_template_file(
                 client(fixture, identity),
                 "ctr one",
                 "path x",
                 chunks(payload, 4_096)
               )

      assert [native, local] = HTTPFixture.requests(fixture)
      assert signature(native) == signature(local)
      assert local.method == "POST" and signature(local)["body"] == payload
      assert signature(local)["content_type"] == "application/octet-stream"
      assert Map.drop(signature(local)["query"], ~w(project target)) == %{"path" => "path x"}
    end

    test "#{transport} S07 native errors are preserved with one request on each side", %{
      driver: driver,
      root: root
    } do
      identity = identity(root, unquote(transport))

      for scenario <- @downloads, code <- [400, 403, 404] do
        fixture =
          backend(root, identity, fn _ ->
            %{status: code, body: %{type: "error", error_code: code, error: "native rejection"}}
          end)

        go = run_go(driver, input(fixture, identity, scenario))
        # The pinned GetMetrics reports the status only in its error text.
        assert go["error_status"] == code or
                 (scenario.action == "GetMetrics" and go["error"] =~ to_string(code))

        assert {<<>>, {:error, %Error{kind: :native, http_status: ^code}}} =
                 with_sink(&download(client(fixture, identity), scenario, &1))

        assert length(HTTPFixture.requests(fixture)) == 2
      end
    end

    test "#{transport} S07 streams are bounded by bytes, chunks and the stream deadline", %{
      root: root
    } do
      identity = identity(root, unquote(transport))

      for scenario <- @downloads do
        payload = payload(scenario)
        fixture = backend(root, identity, fn _ -> bytes(payload) end)

        assert {<<>>, {:error, %Error{kind: :stream_limit}}} =
                 with_sink(
                   &download(client(fixture, identity, max_stream_bytes: 3), scenario, &1)
                 )

        # Chunks handed to the sink never exceed the chunk limit.
        assert {^payload, {:ok, _}} =
                 with_sink(fn sink ->
                   download(
                     client(fixture, identity, max_chunk_bytes: 1_024),
                     scenario,
                     fn chunk ->
                       assert byte_size(chunk) <= 1_024
                       sink.(chunk)
                     end
                   )
                 end)

        # The rest of the body arrives after the stream deadline, so a payload small
        # enough for one read (metrics) still needs a read past the deadline.
        slow = backend(root, identity, fn _ -> split(payload, 100) end)

        assert {:error, %Error{kind: :deadline}} =
                 download(client(slow, identity, stream_timeout: 50), scenario, fn _ ->
                   Process.sleep(200)
                   :ok
                 end)

        assert length(HTTPFixture.requests(fixture)) == 2
        assert length(HTTPFixture.requests(slow)) == 1
      end
    end

    test "#{transport} S07 cancellation and caller loss close the peer and stop the sink", %{
      root: root
    } do
      identity = identity(root, unquote(transport))

      for scenario <- @downloads, mode <- [:cancel, :caller_loss] do
        parent = self()
        tag = make_ref()

        fixture =
          backend(root, identity, fn _ ->
            %{
              upgrade: fn transport, socket ->
                :ok =
                  transport.send(
                    socket,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" <>
                      "Content-Length: 10000000\r\n\r\n"
                  )

                send(parent, {tag, :closed, stream_until_closed(transport, socket)})
              end
            }
          end)

        context = RequestContext.new!(timeout: 30_000)
        scoped = Incus.with_context(client(fixture, identity), context)

        caller =
          spawn(fn ->
            result =
              download(scoped, scenario, fn chunk ->
                send(parent, {tag, :chunk, chunk})
                :ok
              end)

            send(parent, {tag, :result, result})
          end)

        assert_receive {^tag, :chunk, _}, 10_000

        case mode do
          :cancel ->
            RequestContext.cancel(context)
            assert_receive {^tag, :result, {:error, %Error{kind: :canceled}}}, 10_000

          :caller_loss ->
            Process.exit(caller, :kill)
        end

        assert_receive {^tag, :closed, {:error, _}}, 10_000

        # Once the download has stopped, the sink is never called again.
        flush(tag)
        refute_receive {^tag, :chunk, _}, 200
        assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{transport} S07 lost upload reply is uncertain and never replayed", %{root: root} do
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> %{upgrade: fn _, _ -> :ok end} end)

      assert {:error, %Error{kind: :uncertain}} =
               Streams.create_instance_template_file(
                 client(fixture, identity, stream_timeout: 2_000),
                 "ctr one",
                 "path x",
                 [<<1, 2, 3>>]
               )

      assert [%{method: "POST"}] = HTTPFixture.requests(fixture)
    end
  end

  defp download(client, %{action: "GetMetrics"}, sink), do: Streams.metrics(client, sink)

  defp download(client, %{action: "GetNetworkACLLogfile", name: name}, sink),
    do: Streams.network_acl_log(client, name, sink)

  defp download(client, %{action: "GetInstanceLogfile", name: name, filename: file}, sink),
    do: Streams.instance_logfile(client, name, file, sink)

  defp download(client, %{action: "GetInstanceConsoleLog", name: name}, sink),
    do: Streams.instance_console_log(client, name, sink)

  defp download(client, %{action: "GetInstanceTemplateFile", name: name, template: path}, sink),
    do: Streams.instance_template_file(client, name, path, sink)

  defp download(client, %{action: "GetInstanceDebugMemory", name: name, format: format}, sink),
    do: Streams.instance_debug_memory(client, name, format, sink)

  defp payload(%{action: "GetMetrics"}), do: "incus_uptime_seconds 42\n"
  defp payload(_), do: @payload

  defp bytes(payload),
    do: %{
      raw: [
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ",
        Integer.to_string(byte_size(payload)),
        "\r\n\r\n",
        payload
      ]
    }

  # The head and the first byte now, the rest of the body after a delay.
  defp split(<<first::binary-size(1), rest::binary>> = payload, delay),
    do: %{
      wire_chunks: [
        {0,
         IO.iodata_to_binary([
           "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ",
           Integer.to_string(byte_size(payload)),
           "\r\n\r\n",
           first
         ])},
        {delay, rest}
      ]
    }

  defp stream_until_closed(transport, socket) do
    case transport.send(socket, :binary.copy(<<1>>, 64)) do
      :ok ->
        Process.sleep(20)
        stream_until_closed(transport, socket)

      error ->
        error
    end
  end

  defp flush(tag) do
    receive do
      {^tag, :chunk, _} -> flush(tag)
    after
      0 -> :ok
    end
  end

  defp chunks(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunks(binary, size) do
    <<chunk::binary-size(size), rest::binary>> = binary
    [chunk | chunks(rest, size)]
  end

  defp with_sink(fun) do
    capture = start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> [] end]}})

    result =
      fun.(fn chunk ->
        Agent.update(capture, &[chunk | &1])
        :ok
      end)

    {Agent.get(capture, &IO.iodata_to_binary(Enum.reverse(&1))), result}
  end

  # Decoded queries: order and percent-encoding style are not asserted, values are.
  defp signature(%{method: method, target: target, headers: headers, body: body}) do
    uri = URI.parse(target)

    %{
      "method" => method,
      "path" => uri.path,
      "query" => URI.decode_query(uri.query || ""),
      "content_type" => headers["content-type"],
      "body" => body
    }
  end

  defp input(fixture, identity, scenario) do
    endpoint = HTTPFixture.endpoint(fixture)

    scenario
    |> Map.take([:action, :name, :filename, :template, :format])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.merge(%{"project" => "ops", "target" => "node-2", "read_limit" => 1_048_577})
    |> Map.merge(
      if identity,
        do: %{
          "url" => endpoint.url,
          "tls_ca" => File.read!(identity.cafile),
          "client_cert" => File.read!(identity.certfile),
          "client_key" => File.read!(identity.keyfile)
        },
        else: %{"socket" => endpoint.socket}
    )
  end

  defp run_go(driver, input) do
    input =
      input
      |> Map.update("payload", nil, &(&1 && Base.encode64(&1)))
      |> Map.reject(fn {_, value} -> is_nil(value) end)

    path = Path.join(System.tmp_dir!(), "op-s07-input-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(input))
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    {output, status} = System.cmd(driver, [path], stderr_to_stdout: true)
    assert status == 0, output
    Jason.decode!(output)
  end

  defp identity(_root, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "s07-#{System.unique_integer([:positive])}", "localhost")

  # Mutual TLS: the fixture requires and verifies a client certificate from both the
  # pinned client and ours.
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

    start_supervised!({HTTPFixture, options ++ [handler: handler]}, id: make_ref())
  end

  defp client(fixture, identity, opts \\ []) do
    endpoint = HTTPFixture.endpoint(fixture)
    options = [owner: :fixture, project: "ops", member: "node-2", timeout: 30_000] ++ opts

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
      server: %Server{api_extensions: @extensions}
    }
  end
end
