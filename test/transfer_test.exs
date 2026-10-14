defmodule Opsmaru.Incus.TransferTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Transfer}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  setup do
    root = Path.join(System.tmp_dir!(), "op-transfer-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    %{root: root, context: context}
  end

  test "native binary download/upload preserve bytes and headers without JSON encoding", %{
    root: root,
    context: context
  } do
    payload = :binary.copy(<<0, 255, 128, 13, 10, 0>>, 10_000)

    fixture =
      backend(root, fn request ->
        if request.method == "GET" do
          %{
            raw: [
              "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nX-Incus-mode: 0640\r\nETag: native\r\nContent-Length: ",
              Integer.to_string(byte_size(payload)),
              "\r\n\r\n",
              payload
            ]
          }
        else
          assert request.body == payload

          %{
            status: 202,
            body: %{
              type: "async",
              operation: "/1.0/operations/upload",
              metadata: %{id: "upload", status_code: 103}
            }
          }
        end
      end)

    client = client(fixture, context, max_chunk_bytes: 1024)
    {:ok, capture} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(capture), do: Agent.stop(capture) end)

    sink = fn chunk ->
      assert byte_size(chunk) <= 1024
      Agent.update(capture, &[chunk | &1])
    end

    assert {:ok, downloaded} = Transfer.download(client, "/1.0/images/fingerprint/export", sink)
    assert downloaded.bytes == byte_size(payload)
    assert downloaded.headers["x-incus-mode"] == "0640"
    assert downloaded.headers["etag"] == "native"

    assert Agent.get(capture, fn chunks -> IO.iodata_to_binary(Enum.reverse(chunks)) end) ==
             payload

    chunks = for <<chunk::binary-size(1000) <- payload>>, do: chunk

    assert {:ok, accepted} =
             Transfer.upload(client, "/1.0/images", chunks, [
               {"content-type", "application/octet-stream"}
             ])

    assert accepted.operation == "/1.0/operations/upload"
    assert [_, request] = HTTPFixture.requests(fixture)
    assert request.headers["transfer-encoding"] == "chunked"
    assert request.headers["content-type"] == "application/octet-stream"
  end

  test "sink/source/deadline limits close only the local stream and never replay mutations", %{
    root: root,
    context: context
  } do
    payload = <<0, 255, 128, 0>>

    fixture =
      backend(root, fn request ->
        if request.method == "GET",
          do: %{raw: ["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n", payload]},
          else: %{raw: ""}
      end)

    client = client(fixture, context, max_stream_bytes: 3, stream_timeout: 30)

    assert {:error, %Error{kind: :stream_limit}} =
             Transfer.download(client, "/1.0/files", fn _ -> :ok end)

    client = %{client | connection: %{client.connection | max_stream_bytes: 100}}

    assert {:error, %Error{kind: :deadline}} =
             Transfer.download(client, "/1.0/files", fn _ ->
               Process.sleep(100)
               :ok
             end)

    assert {:error, %Error{kind: :uncertain}} = Transfer.upload(client, "/1.0/images", [payload])
    assert length(HTTPFixture.requests(fixture)) == 3

    assert {:error, %Error{kind: :invalid_headers}} =
             Transfer.upload(client, "/1.0/images", [], [
               {"x-incus-filename", "file\r\ninjected: yes"}
             ])
  end

  test "explicit server pin validates identity/key possession and cannot accept another server",
       %{root: root, context: context} do
    server = TLSIdentity.generate(root, "pinned", "localhost")
    client_identity = TLSIdentity.generate(root, "client", "client")

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: server.certfile,
         keyfile: server.keyfile,
         handler: fn _ -> %{status: 200, body: %{type: "sync", metadata: nil}} end}
      )

    tls = [
      fingerprint: Base.encode16(:crypto.hash(:sha256, server.der), case: :lower),
      certfile: client_identity.certfile,
      keyfile: client_identity.keyfile
    ]

    connection = Connection.https!(HTTPFixture.endpoint(fixture).url, owner: :fixture, tls: tls)
    assert {:ok, _} = Incus.raw_query(connection, context, "GET", "/1.0", [])
    wrong = %{connection | tls: Keyword.put(tls, :fingerprint, String.duplicate("0", 64))}

    assert {:error, %Error{kind: :connection}} =
             Incus.raw_query(wrong, context, "GET", "/1.0", [])

    wrong_name = %{connection | address: %{connection.address | host: "127.0.0.1"}}

    assert {:error, %Error{kind: :connection}} =
             Incus.raw_query(wrong_name, context, "GET", "/1.0", [])
  end

  for mode <- [:source, :sink] do
    test "trapping #{mode} callback cannot survive its calling owner", %{
      root: root,
      context: context
    } do
      fixture = backend(root, fn _ -> %{raw: "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"} end)
      client = client(fixture, context, stream_timeout: 5_000)
      parent = self()

      block = fn ->
        Process.flag(:trap_exit, true)
        send(parent, {:blocked, self()})

        receive do
          :never -> :ok
        end
      end

      owner = spawn(fn -> trapped_transfer(unquote(mode), client, block) end)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
      assert_receive {:blocked, worker}, 1_000
      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      monitor = Process.monitor(worker)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 500
      assert Process.alive?(self())
    end
  end

  defp trapped_transfer(:source, client, block) do
    source =
      Stream.map([<<7>>], fn bytes ->
        block.()
        bytes
      end)

    Transfer.upload(client, "/1.0/images", source)
  end

  defp trapped_transfer(:sink, client, block),
    do: Transfer.download(client, "/1.0/files", fn _ -> block.() end)

  defp client(fixture, context, opts) do
    connection =
      Connection.unix!(
        HTTPFixture.endpoint(fixture).socket,
        Keyword.merge([owner: :fixture], opts)
      )

    %Incus{
      connection: connection,
      context: context,
      server: %Opsmaru.Incus.Server{api_extensions: []}
    }
  end

  defp backend(root, handler),
    do:
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "sock-#{System.unique_integer([:positive])}"),
         handler: handler},
        id: make_ref()
      )
end
