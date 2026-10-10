defmodule Opsmaru.Incus.StreamsTest do
  @moduledoc """
  Differential and behavior fixtures for Opsmaru.Incus.Streams against the
  pinned official Incus v7.0.1 client. The Go driver under test/reference
  invokes the unchanged typed methods; request maps and bytes are compared
  semantically (decoded query maps, raw body bytes). Fixture-only evidence;
  no real backend, workload or filesystem transfer is exercised.
  """
  use ExUnit.Case, async: false

  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Response, Server, Streams}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  @reference_dir Path.expand("../reference", __DIR__)
  @extensions ["metrics", "network_acl_log", "console", "container_edit_metadata"]
  @binary_payload :binary.copy(<<0, 255, 128, 13, 10, 0, 97>>, 3_000)

  setup_all do
    {module, 0} =
      System.cmd(
        "mise",
        ["exec", "--", "go", "list", "-m", "-json", "github.com/lxc/incus/v7"],
        cd: @reference_dir,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    assert Jason.decode!(module)["Version"] == "v7.0.1"
    assert Jason.decode!(File.read!("priv/incus/reference.json"))["tag"] == "v7.0.1"

    driver =
      Path.join(System.tmp_dir!(), "op-streams-driver-#{System.unique_integer([:positive])}")

    {output, status} =
      System.cmd(
        "mise",
        ["exec", "--", "go", "build", "-o", driver, "./streams"],
        cd: @reference_dir,
        stderr_to_stdout: true,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    assert status == 0, output
    on_exit(fn -> File.rm(driver) end)
    %{driver: driver}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-streams-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "pinned official typed client and Elixir wrappers agree on requests and bytes", %{
    driver: driver,
    root: root
  } do
    scenarios = [
      %{
        action: "GetMetrics",
        path: "/1.0/metrics",
        query: %{},
        name: nil,
        filename: nil,
        template: nil,
        format: nil
      },
      %{
        action: "GetNetworkACLLogfile",
        path: "/1.0/network-acls/acl%20one/log",
        query: %{},
        name: "acl one",
        filename: nil,
        template: nil,
        format: nil
      },
      %{
        action: "GetInstanceLogfile",
        path: "/1.0/instances/vm%20one/logs/server.log",
        query: %{"project" => "ops", "target" => "node-2"},
        name: "vm one",
        filename: "server.log",
        template: nil,
        format: nil,
        project: "ops",
        member: "node-2"
      },
      %{
        action: "GetInstanceConsoleLog",
        path: "/1.0/instances/vm%20one/console",
        query: %{},
        name: "vm one",
        filename: nil,
        template: nil,
        format: nil
      },
      %{
        action: "GetInstanceTemplateFile",
        path: "/1.0/instances/ctr%20one/metadata/templates",
        query: %{"path" => "a b/c=d&f"},
        name: "ctr one",
        filename: nil,
        template: "a b/c=d&f",
        format: nil
      },
      %{
        action: "GetInstanceDebugMemory",
        path: "/1.0/instances/vm%20one/debug/memory",
        query: %{"format" => "v2", "instance-type" => "virtual-machine"},
        name: "vm one",
        filename: nil,
        template: nil,
        format: "v2"
      }
    ]

    listing_before = File.ls!(root)

    for scenario <- scenarios do
      payload =
        if scenario.action == "GetMetrics", do: "incus_uptime_seconds 42\n", else: @binary_payload

      fixture =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(root, "sock-#{scenario.action}"),
           handler: fn _ ->
             %{
               raw: [
                 "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ",
                 Integer.to_string(byte_size(payload)),
                 "\r\n\r\n",
                 payload
               ]
             }
           end},
          id: scenario.action
        )

      go_input =
        fixture_input(fixture, scenario)
        |> Map.put("project", scenario[:project] || "")
        |> Map.put("target", scenario[:member] || "")

      go = run_go(driver, go_input)
      assert go["error"] == nil
      go_bytes = Base.decode64!(go["bytes"])

      selection = Map.to_list(Map.take(scenario, [:project, :member]))

      {elixir_bytes, result} =
        with_sink(fn sink ->
          elixir_call(scenario, client(fixture, selection), sink)
        end)

      assert {:ok, %Opsmaru.Incus.Transfer{} = transfer} = result
      assert transfer.bytes == byte_size(payload)
      assert elixir_bytes == go_bytes

      # HTTPFixture records requests chronologically: the Go driver first.
      assert [go_request, elixir_request] = HTTPFixture.requests(fixture)
      assert request_signature(go_request) == request_signature(elixir_request)
      assert request_signature(elixir_request)["path"] == scenario.path
      assert request_signature(elixir_request)["query"] == scenario.query
      assert request_signature(elixir_request)["method"] == "GET"

      stop_supervised!(scenario.action)
    end

    assert File.ls!(root) == listing_before
  end

  test "official typed client and Elixir wrapper agree on template file upload bytes", %{
    driver: driver,
    root: root
  } do
    payload = :binary.copy(<<0, 254, 7>>, 20_000)

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "upload-sock"),
         handler: fn _ ->
           %{
             status: 200,
             headers: %{"ETag" => "tpl"},
             body: %{type: "sync", status: "Success", status_code: 200, metadata: %{}}
           }
         end},
        id: :upload
      )

    go =
      run_go(
        driver,
        fixture_input(fixture, %{
          action: "CreateInstanceTemplateFile",
          name: "ctr one",
          template: "path x"
        })
        |> Map.put("payload", payload)
      )

    assert go["error"] == nil

    chunks = chunk_split(payload, 4_096)

    assert {:ok, %Response{} = response} =
             Streams.create_instance_template_file(
               client(fixture, []),
               "ctr one",
               "path x",
               chunks
             )

    assert response.type == "sync"
    assert response.etag == "tpl"

    assert [go_request, elixir_request] = HTTPFixture.requests(fixture)
    assert request_signature(go_request) == request_signature(elixir_request)

    assert request_signature(elixir_request)["path"] ==
             "/1.0/instances/ctr%20one/metadata/templates"

    assert request_signature(elixir_request)["query"] == %{"path" => "path x"}
    assert request_signature(elixir_request)["method"] == "POST"
    assert request_signature(elixir_request)["content_type"] == "application/octet-stream"
    assert request_signature(elixir_request)["body"] == payload
    assert go_request.headers["content-length"] == Integer.to_string(byte_size(payload))
    assert elixir_request.headers["transfer-encoding"] == "chunked"
    stop_supervised!(:upload)
  end

  test "verified TLS 1.3 transport preserves stream bytes against the official client", %{
    driver: driver,
    root: root
  } do
    identity = TLSIdentity.generate(root, "streams-tls", "localhost")
    payload = <<0, 255, 128, 10, 0, 114>>
    payload_size = byte_size(payload)

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: identity.certfile,
         keyfile: identity.keyfile,
         handler: fn _ ->
           %{
             raw: [
               "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ",
               Integer.to_string(payload_size),
               "\r\n\r\n",
               payload
             ]
           }
         end},
        id: :tls
      )

    endpoint = HTTPFixture.endpoint(fixture)

    go =
      run_go(
        driver,
        fixture_input(fixture, %{action: "GetInstanceLogfile", name: "vm one", filename: "log"})
        |> Map.put("url", endpoint.url)
        |> Map.put("server_cert", File.read!(identity.certfile))
      )

    assert go["error"] == nil

    connection =
      Connection.https!(endpoint.url,
        owner: :fixture,
        tls: [
          cacertfile: identity.cafile,
          certfile: identity.certfile,
          keyfile: identity.keyfile
        ]
      )

    client = %Incus{
      connection: connection,
      context: context(),
      server: %Server{api_extensions: @extensions}
    }

    {elixir_bytes, result} =
      with_sink(fn sink -> Streams.instance_logfile(client, "vm one", "log", sink) end)

    assert {:ok, %Opsmaru.Incus.Transfer{bytes: ^payload_size}} = result
    assert elixir_bytes == Base.decode64!(go["bytes"])

    assert [go_request, elixir_request] = HTTPFixture.requests(fixture)
    assert request_signature(go_request) == request_signature(elixir_request)
    stop_supervised!(:tls)
  end

  test "native error envelopes are preserved with a single request on each side", %{
    driver: driver,
    root: root
  } do
    error_envelope = fn status, code, message ->
      %{
        status: status,
        body: %{
          type: "error",
          error_code: code,
          error: message,
          status: "Error",
          status_code: status
        }
      }
    end

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "error-sock"),
         handler: fn request ->
           path = URI.parse(request.target).path

           if request.method == "POST" do
             error_envelope.(500, 500, "backend failed")
           else
             if path == "/1.0/metrics" do
               error_envelope.(500, 500, "metrics failed")
             else
               error_envelope.(404, 1, "instance not found")
             end
           end
         end},
        id: :error
      )

    client = client(fixture, [])

    go =
      run_go(
        driver,
        fixture_input(fixture, %{
          action: "GetInstanceLogfile",
          name: "vm one",
          filename: "server.log"
        })
      )

    assert go["error"] == "instance not found"
    assert go["error_status"] == 404

    {bytes, result} =
      with_sink(fn sink -> Streams.instance_logfile(client, "vm one", "server.log", sink) end)

    assert bytes == <<>>
    # Explicit native envelopes keep kind :native with the HTTP status and the
    # native error code, matching the Go StatusErrorMatch split.
    assert {:error,
            %Error{kind: :native, http_status: 404, error_code: 1, message: "instance not found"}} =
             result

    go = run_go(driver, fixture_input(fixture, %{action: "GetMetrics"}))
    assert go["error"] =~ "500"

    {bytes, result} = with_sink(fn sink -> Streams.metrics(client, sink) end)
    assert bytes == <<>>
    assert {:error, %Error{kind: :native, http_status: 500, message: "metrics failed"}} = result

    go =
      run_go(
        driver,
        fixture_input(fixture, %{
          action: "CreateInstanceTemplateFile",
          name: "vm one",
          template: "t"
        })
      )

    assert go["error"] == "backend failed"
    assert go["error_status"] == 500

    assert {:error,
            %Error{kind: :native, http_status: 500, error_code: 500, message: "backend failed"}} =
             Streams.create_instance_template_file(client, "vm one", "t", [<<1, 2, 3>>])

    # One request per side per attempt: no automatic replay.
    assert length(HTTPFixture.requests(fixture)) == 6
    stop_supervised!(:error)
  end

  test "a lost mutation response is reported uncertain and never replayed", %{root: root} do
    fixture =
      start_supervised!(
        {
          HTTPFixture,
          # The fixture accepts the POST, then drops the connection without any
          # response: the mutation may have been accepted.
          transport: :gen_tcp, path: Path.join(root, "lost-sock"), handler: fn _ -> %{raw: ""} end
        },
        id: :lost
      )

    client = client(fixture, stream_timeout: 500)

    assert {:error, %Error{kind: :uncertain}} =
             Streams.create_instance_template_file(client, "vm one", "t", [<<1, 2, 3>>])

    # Exactly one POST reached the fixture: no blind retry of a possibly
    # accepted mutation.
    assert [request] = HTTPFixture.requests(fixture)
    assert request.method == "POST"
    stop_supervised!(:lost)
  end

  test "missing extensions fail before any backend contact", %{root: root} do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "missing-sock"),
         handler: fn _ -> %{status: 200, body: %{type: "sync", metadata: nil}} end},
        id: :missing
      )

    client = %Incus{
      connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
      context: context(),
      server: %Server{api_extensions: []}
    }

    assert {:error, %Error{kind: :unsupported_extension, extension: "metrics"}} =
             Streams.metrics(client, fn _ -> :ok end)

    assert {:error, %Error{kind: :unsupported_extension, extension: "network_acl_log"}} =
             Streams.network_acl_log(client, "acl", fn _ -> :ok end)

    assert {:error, %Error{kind: :unsupported_extension, extension: "console"}} =
             Streams.instance_console_log(client, "vm", fn _ -> :ok end)

    assert {:error, %Error{kind: :unsupported_extension, extension: "container_edit_metadata"}} =
             Streams.instance_template_file(client, "vm", "t", fn _ -> :ok end)

    assert {:error, %Error{kind: :unsupported_extension, extension: "container_edit_metadata"}} =
             Streams.create_instance_template_file(client, "vm", "t", [<<1>>])

    # Argument validation is also reported with the Error contract. Methods
    # without an extension gate reach the argument check directly.
    assert {:error, %Error{kind: :invalid_arguments}} =
             Streams.instance_logfile(client, "", "server.log", fn _ -> :ok end)

    extended = %{client | server: %Server{api_extensions: @extensions}}

    assert {:error, %Error{kind: :invalid_arguments}} =
             Streams.instance_template_file(extended, "vm", "bad\r\nname", fn _ -> :ok end)

    # Nothing reached the fake backend.
    assert HTTPFixture.requests(fixture) == []
    stop_supervised!(:missing)
  end

  test "byte bounds, deadlines and chunk limits bound the stream without retry", %{root: root} do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "bounds-sock"),
         handler: fn _ ->
           %{raw: ["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n", <<0, 255, 128, 0>>]}
         end},
        id: :bounds
      )

    assert {<<>>, {:error, %Error{kind: :stream_limit}}} =
             with_sink(fn sink ->
               Streams.instance_logfile(
                 client(fixture, max_stream_bytes: 3),
                 "vm",
                 "server.log",
                 sink
               )
             end)

    assert {<<>>, {:error, %Error{kind: :deadline}}} =
             with_sink(fn _sink ->
               Streams.instance_logfile(
                 client(fixture, stream_timeout: 30),
                 "vm",
                 "server.log",
                 fn _ ->
                   Process.sleep(100)
                   :ok
                 end
               )
             end)

    assert length(HTTPFixture.requests(fixture)) == 2

    chunk_fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "chunk-sock"),
         handler: fn _ ->
           %{
             raw: [
               "HTTP/1.1 200 OK\r\nContent-Length: ",
               Integer.to_string(byte_size(@binary_payload)),
               "\r\n\r\n",
               @binary_payload
             ]
           }
         end},
        id: :chunk
      )

    stream_size = byte_size(@binary_payload)

    assert {@binary_payload, {:ok, %Opsmaru.Incus.Transfer{bytes: ^stream_size}}} =
             with_sink(fn sink ->
               validating = fn chunk ->
                 if byte_size(chunk) > 1_024, do: raise("sink chunk exceeded max_chunk_bytes")
                 sink.(chunk)
               end

               Streams.instance_logfile(
                 client(chunk_fixture, max_chunk_bytes: 1_024),
                 "vm",
                 "server.log",
                 validating
               )
             end)

    stop_supervised!(:bounds)
    stop_supervised!(:chunk)
  end

  test "caller exit mid-stream closes only the local stream and leaves the fixture usable", %{
    root: root
  } do
    stream = :binary.copy(<<7>>, 3_000)

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "caller-sock"),
         handler: fn _ ->
           head = "HTTP/1.1 200 OK\r\nContent-Length: 3000\r\n\r\n"
           chunks = for <<chunk::binary-size(1_500) <- stream>>, do: {100, chunk}
           %{wire_chunks: [{0, head}] ++ chunks}
         end},
        id: :caller
      )

    client = client(fixture, stream_timeout: 5_000)
    parent = self()

    child =
      spawn(fn ->
        Streams.instance_logfile(client, "vm", "server.log", fn _ ->
          send(parent, {:sink_started, self()})

          receive do
            :release -> :ok
          after
            1000 -> :ok
          end
        end)
      end)

    assert_receive {:sink_started, worker}, 5000
    monitor = Process.monitor(worker)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000

    # The fixture remains usable for an unrelated request after the caller died.
    assert {^stream, {:ok, %Opsmaru.Incus.Transfer{}}} =
             with_sink(fn sink -> Streams.metrics(client, sink) end)

    stop_supervised!(:caller)
  end

  test "stream helpers perform no implicit filesystem writes", %{root: root} do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "no-write-sock"),
         handler: fn request ->
           if request.method == "POST" do
             %{
               status: 200,
               body: %{type: "sync", status: "Success", status_code: 200, metadata: %{}}
             }
           else
             %{
               raw:
                 "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 0\r\n\r\n"
             }
           end
         end},
        id: :nowrite
      )

    client = client(fixture, [])
    listing_before = File.ls!(root)

    assert {:ok, %Response{}} =
             Streams.create_instance_template_file(client, "vm one", "a b", [<<1, 2, 3>>])

    assert {<<>>, {:ok, %Opsmaru.Incus.Transfer{bytes: 0}}} =
             with_sink(fn sink ->
               Streams.instance_template_file(client, "vm one", "a b", sink)
             end)

    assert File.ls!(root) == listing_before
    stop_supervised!(:nowrite)
  end

  defp context, do: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)

  defp client(fixture, opts) do
    connection =
      Connection.unix!(
        HTTPFixture.endpoint(fixture).socket,
        Keyword.merge(
          [owner: :fixture],
          Keyword.take(opts, [
            :project,
            :member,
            :stream_timeout,
            :max_stream_bytes,
            :max_chunk_bytes
          ])
        )
      )

    %Incus{
      connection: connection,
      context: context(),
      server: %Server{api_extensions: @extensions}
    }
  end

  defp elixir_call(%{action: "GetMetrics"}, client, sink), do: Streams.metrics(client, sink)

  defp elixir_call(%{action: "GetNetworkACLLogfile", name: name}, client, sink),
    do: Streams.network_acl_log(client, name, sink)

  defp elixir_call(%{action: "GetInstanceLogfile", name: name, filename: filename}, client, sink),
    do: Streams.instance_logfile(client, name, filename, sink)

  defp elixir_call(%{action: "GetInstanceConsoleLog", name: name}, client, sink),
    do: Streams.instance_console_log(client, name, sink)

  defp elixir_call(
         %{action: "GetInstanceTemplateFile", name: name, template: template},
         client,
         sink
       ),
       do: Streams.instance_template_file(client, name, template, sink)

  defp elixir_call(%{action: "GetInstanceDebugMemory", name: name, format: format}, client, sink),
    do: Streams.instance_debug_memory(client, name, format, sink)

  defp with_sink(fun) do
    capture = start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> [] end]}})

    result =
      fun.(fn chunk ->
        Agent.update(capture, &[chunk | &1])
        :ok
      end)

    bytes = Agent.get(capture, &IO.iodata_to_binary(Enum.reverse(&1)))
    {bytes, result}
  end

  defp chunk_split(binary, size) do
    Stream.unfold(binary, fn
      rest when byte_size(rest) == 0 ->
        nil

      rest ->
        <<head::binary-size(min(size, byte_size(rest))), tail::binary>> = rest
        {head, tail}
    end)
  end

  defp request_signature(%{method: method, target: target, headers: headers, body: body}) do
    uri = URI.parse(target)

    %{
      "method" => method,
      "path" => uri.path,
      # Decoded maps: query order and percent-encoding style are not asserted,
      # values are.
      "query" => URI.decode_query(uri.query || ""),
      "content_type" => headers["content-type"],
      "body" => body
    }
  end

  defp fixture_input(fixture, scenario) do
    endpoint = HTTPFixture.endpoint(fixture)

    base = Map.new(scenario, fn {key, value} -> {to_string(key), value} end)

    base
    |> maybe_put_socket(endpoint)
    |> Map.put("read_limit", 1_048_577)
  end

  defp maybe_put_socket(input, %{socket: socket}), do: Map.put(input, "socket", socket)
  defp maybe_put_socket(input, _endpoint), do: input

  defp run_go(driver, input) do
    input =
      Map.take(
        input,
        ~w(socket url server_cert project target action name filename template format payload read_limit)
      )
      |> Map.update("payload", nil, fn
        nil -> nil
        binary -> Base.encode64(binary)
      end)
      |> Map.drop(for {key, value} <- input, is_nil(value) or value == "", do: key)

    input_path =
      Path.join(System.tmp_dir!(), "op-streams-input-#{System.unique_integer([:positive])}.json")

    File.write!(input_path, Jason.encode!(input))
    File.chmod!(input_path, 0o600)
    on_exit(fn -> File.rm(input_path) end)

    {output, status} = System.cmd(driver, [input_path], stderr_to_stdout: true)
    assert status == 0, output
    Jason.decode!(output)
  end
end
