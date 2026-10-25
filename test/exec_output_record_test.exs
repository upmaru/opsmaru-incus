defmodule Opsmaru.Incus.ExecOutputRecordTest do
  @moduledoc "B07 recorded exec output download, evidenced by independent native fixtures."
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, RequestContext, Server, Streams, Transfer}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  # Binary output, including bytes that are not valid UTF-8.
  @payload <<0, 255, 128, "stdout line\n", 0, 7>>
  @path "/1.0/instances/vm%20one/logs/exec-output/exec%20output.stdout"

  setup do
    root = Path.join(System.tmp_dir!(), "op-xo-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} recorded exec output streams one file to an acknowledged sink and never deletes",
         %{root: root} do
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> bytes(@payload) end)
      client = client(fixture, identity)
      size = byte_size(@payload)

      assert {@payload, {:ok, %Transfer{bytes: ^size}}} =
               with_sink(
                 &Streams.instance_exec_output(client, "vm one", "exec output.stdout", &1)
               )

      # One GET with host routing; no implicit delete follows the download.
      assert [request] = HTTPFixture.requests(fixture)
      assert request.method == "GET" and URI.parse(request.target).path == @path

      assert URI.decode_query(URI.parse(request.target).query) == %{
               "project" => "fixture scope",
               "target" => "member/a"
             }
    end

    test "#{transport} missing or rejected recorded output keeps the native error", %{root: root} do
      identity = identity(root, unquote(transport))

      for code <- [400, 403, 404] do
        fixture =
          backend(root, identity, fn _ ->
            %{status: code, body: %{type: "error", error_code: code, error: "native rejection"}}
          end)

        assert {<<>>, {:error, %Error{kind: :native, http_status: ^code}}} =
                 with_sink(
                   &Streams.instance_exec_output(
                     client(fixture, identity),
                     "vm one",
                     "exec output.stdout",
                     &1
                   )
                 )

        assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{transport} recorded output download is bounded and ends with its lifetime", %{
      root: root
    } do
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> bytes(@payload) end)

      assert {<<>>, {:error, %Error{kind: :stream_limit}}} =
               with_sink(
                 &Streams.instance_exec_output(
                   client(fixture, identity, max_stream_bytes: 3),
                   "vm one",
                   "exec output.stdout",
                   &1
                 )
               )

      # A stalled sink is cut off by the stream deadline, without retry.
      assert {:error, %Error{kind: :deadline}} =
               Streams.instance_exec_output(
                 client(fixture, identity, stream_timeout: 50),
                 "vm one",
                 "exec output.stdout",
                 fn _ ->
                   Process.sleep(200)
                   :ok
                 end
               )

      # A canceled request context stops the download before any I/O.
      context = RequestContext.new!(timeout: 30_000)
      RequestContext.cancel(context)
      scoped = Incus.with_context(client(fixture, identity), context)

      assert {:error, %Error{kind: :canceled}} =
               Streams.instance_exec_output(scoped, "vm one", "exec output.stdout", fn _ ->
                 :ok
               end)

      assert length(HTTPFixture.requests(fixture)) == 2
    end

    test "#{transport} unsafe names and a missing extension reject before I/O", %{root: root} do
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> flunk("rejected download was dispatched") end)
      client = client(fixture, identity)

      for {name, file} <- [
            {"", "exec.stdout"},
            {"vm one", ""},
            {"vm one", "."},
            {"vm one", ".."},
            {"vm one", "dir/exec.stdout"}
          ] do
        assert {:error, %Error{kind: :invalid_arguments}} =
                 Streams.instance_exec_output(client, name, file, fn _ -> :ok end)
      end

      missing = %{client | server: %Server{api_extensions: []}}

      assert {:error, %Error{kind: :unsupported_extension, extension: "container_exec_recording"}} =
               Streams.instance_exec_output(missing, "vm one", "exec.stdout", fn _ -> :ok end)

      assert HTTPFixture.requests(fixture) == []
    end
  end

  defp bytes(payload),
    do: %{
      raw: [
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ",
        Integer.to_string(byte_size(payload)),
        "\r\n\r\n",
        payload
      ]
    }

  defp with_sink(fun) do
    capture = start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> [] end]}})

    result =
      fun.(fn chunk ->
        Agent.update(capture, &[chunk | &1])
        :ok
      end)

    {Agent.get(capture, &IO.iodata_to_binary(Enum.reverse(&1))), result}
  end

  defp identity(_root, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "xo-#{System.unique_integer([:positive])}", "localhost")

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

    options =
      [owner: :fixture, project: "fixture scope", member: "member/a", timeout: 30_000] ++ opts

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
      server: %Server{api_extensions: ["container_exec_recording"]}
    }
  end
end
