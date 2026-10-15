defmodule Opsmaru.Incus.PrivateImageReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Images, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}
  @driver Path.expand("../.integration/incus-private-image-driver", __DIR__)
  @secret "private+/token? é&="

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

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
    root = Path.join(System.tmp_dir!(), "op-private-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    }
  end

  for transport <- [:gen_tcp, :ssl], split <- [false, true] do
    test "#{transport} private image native download matches bytes, names and selection (split=#{split})",
         %{root: root, context: context} do
      transport = unquote(transport)
      split = unquote(split)
      identity = identity(transport, root, "image")
      metadata = <<0, 255, 128, 13, 10>>
      rootfs = if split, do: <<128, 0, 255, 42>>, else: ""
      fingerprint = Base.encode16(:crypto.hash(:sha256, metadata <> rootfs), case: :lower)
      body = if split, do: multipart(metadata, rootfs), else: metadata

      content_type =
        if split,
          do: "multipart/form-data; boundary=fixture-private",
          else: "application/octet-stream"

      reply = %{
        raw:
          "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nContent-Type: #{content_type}\r\nContent-Disposition: attachment; filename=\"metadata.tar\"\r\n\r\n" <>
            body
      }

      fixture = backend(root, identity, reply)
      endpoint = HTTPFixture.endpoint(fixture)

      input =
        Map.merge(endpoint, %{
          transfer: "download_private_image",
          fingerprint: fingerprint,
          secret: @secret,
          project: "project +",
          target: "member +"
        })

      input =
        oracle_tls(input, identity)

      result = driver(root, input)
      refute result["error"]
      assert Base.decode64!(result["metadata"]) == metadata
      assert Base.decode64!(result["rootfs"]) == rootfs
      native = List.last(HTTPFixture.requests(fixture))
      client = client(fixture, context, identity)
      client = %{client | connection: %{client.connection | max_chunk_bytes: 3}}
      capture = start_supervised!({Agent, fn -> %{metadata: [], rootfs: []} end})

      sinks =
        Map.new([:metadata, :rootfs], fn kind ->
          {kind,
           fn bytes ->
             assert byte_size(bytes) <= 3
             Agent.update(capture, &Map.update!(&1, kind, fn chunks -> [bytes | chunks] end))
           end}
        end)

      {download, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Images.download(client, fingerprint, sinks, secret: @secret)
        end)

      assert {:ok, transfer} = download
      refute log =~ @secret
      refute inspect(transfer) =~ @secret
      assert transfer.result.sha256 == fingerprint
      assert transfer.result.names.metadata == result["response"]["MetaName"]
      assert transfer.result.sizes.metadata == result["response"]["MetaSize"]
      assert transfer.result.sizes.rootfs == result["response"]["RootfsSize"]

      assert Agent.get(capture, fn chunks ->
               Enum.reverse(chunks.metadata) |> IO.iodata_to_binary()
             end) == metadata

      assert Agent.get(capture, fn chunks ->
               Enum.reverse(chunks.rootfs) |> IO.iodata_to_binary()
             end) == rootfs

      actual = List.last(HTTPFixture.requests(fixture))

      assert WireComparison.request(native)["query"] == WireComparison.request(actual)["query"]

      assert :ok =
               WireComparison.compare(
                 WireComparison.request(native),
                 WireComparison.request(actual)
               )

      assert URI.decode_query(URI.parse(actual.target).query) == %{
               "project" => "project +",
               "target" => "member +",
               "secret" =>
                 URI.encode_query(secret: @secret) |> String.replace_prefix("secret=", "")
             }
    end
  end

  test "private-token rejection retains native error and emits one GET", %{
    root: root,
    context: context
  } do
    reply = %{
      status: 403,
      headers: %{"ETag" => "private-etag"},
      body: %{type: "error", error_code: 403, error: "private token rejected"}
    }

    fixture = backend(root, nil, reply)

    result =
      driver(root, %{
        socket: HTTPFixture.endpoint(fixture).socket,
        transfer: "download_private_image",
        fingerprint: "fingerprint",
        secret: @secret
      })

    assert result["error_status"] == 403
    before = length(HTTPFixture.requests(fixture))
    client = client(fixture, context, nil)

    assert {:error, %Error{kind: :native, error_code: 403} = error} =
             Images.download(
               client,
               "fingerprint",
               %{metadata: fn _ -> :ok end},
               secret: @secret
             )

    assert error.message == result["error"]
    assert error.response.etag == "private-etag"
    assert error.response.connection == client.connection
    assert error.response.identity == context.identity
    refute inspect(error) =~ @secret
    # discovery and exactly one export
    assert length(HTTPFixture.requests(fixture)) == before + 2
  end

  test "invalid download arguments fail before contacting a backend", %{
    root: root,
    context: context
  } do
    client = %Incus{
      connection: Connection.unix!(Path.join(root, "absent"), owner: :fixture),
      context: context,
      server: %Server{}
    }

    for {fingerprint, sinks, opts} <- [
          {"", %{metadata: fn _ -> :ok end}, []},
          {"fp", %{}, []},
          {"fp", %{metadata: :bad}, []},
          {"fp", %{metadata: fn _ -> :ok end}, [secret: 1]},
          {"fp", %{metadata: fn _ -> :ok end}, [secret: "one", secret: "two"]},
          {"fp", %{metadata: fn _ -> :ok end}, [unknown: "token"]}
        ] do
      assert {:error, %Error{kind: :invalid_image_arguments}} =
               Images.download(client, fingerprint, sinks, opts)
    end
  end

  test "private download deadline and sink rejection never retry or remove data", %{
    root: root,
    context: context
  } do
    body = <<0, 255, 128>>
    fingerprint = Base.encode16(:crypto.hash(:sha256, body), case: :lower)

    for {sink, timeout} <- [
          {fn _ -> {:error, :host_sink_failed} end, 1000},
          {fn _ ->
             Process.sleep(100)
             :ok
           end, 20}
        ] do
      reply = %{
        raw:
          "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Disposition: attachment; filename=\"metadata.tar\"\r\n\r\n" <>
            body
      }

      fixture = backend(root, nil, reply)
      client = client(fixture, context, nil)
      client = %{client | connection: %{client.connection | stream_timeout: timeout}}

      assert {:error, %Error{}} =
               Images.download(client, fingerprint, %{metadata: sink}, secret: @secret)

      assert [%{method: "GET"}, %{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  defp multipart(meta, rootfs),
    do:
      ~s(--fixture-private\r\nContent-Disposition: form-data; name="metadata"; filename="metadata.tar"\r\nContent-Type: application/octet-stream\r\n\r\n) <>
        meta <>
        ~s(\r\n--fixture-private\r\nContent-Disposition: form-data; name="rootfs.img"; filename="rootfs.img"\r\nContent-Type: application/octet-stream\r\n\r\n) <>
        rootfs <> "\r\n--fixture-private--\r\n"

  defp backend(root, identity, reply) do
    opts =
      if identity,
        do: [transport: :ssl, certfile: identity.certfile, keyfile: identity.keyfile],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "s-#{System.unique_integer([:positive])}")
        ]

    start_supervised!(
      {HTTPFixture,
       opts ++
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
               else: reply
           end
         ]},
      id: make_ref()
    )
  end

  defp client(fixture, context, identity) do
    endpoint = HTTPFixture.endpoint(fixture)

    connection =
      if identity,
        do:
          Connection.https!(endpoint.url,
            owner: :fixture,
            project: "project +",
            member: "member +",
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          ),
        else:
          Connection.unix!(endpoint.socket,
            owner: :fixture,
            project: "project +",
            member: "member +"
          )

    {:ok, client} = Incus.connect(connection, context)
    client
  end

  defp oracle_tls(input, nil), do: input

  defp oracle_tls(input, identity),
    do: Map.put(input, :server_cert, File.read!(identity.certfile))

  defp identity(:gen_tcp, _, _), do: nil
  defp identity(:ssl, root, name), do: TLSIdentity.generate(root, name, "localhost")

  defp driver(root, input) do
    file = Path.join(root, "input.json")
    File.write!(file, Jason.encode!(input))
    File.chmod!(file, 0o600)
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end
end
