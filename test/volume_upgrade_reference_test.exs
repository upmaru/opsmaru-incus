defmodule Opsmaru.Incus.VolumeUpgradeReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, RawChannel, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}
  @driver Path.expand("../../.integration/incus-volume-upgrade-driver", __DIR__)
  @initial <<0, 255, 128>>
  @payload <<255, 0, 128, 13, 10>>
  @extensions ["custom_volume_sftp", "storage_volume_nbd"]

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-vup-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    }
  end

  for transport <- [:gen_tcp, :ssl],
      {protocol, writable} <- [{"sftp", false}, {"nbd", false}, {"nbd", true}] do
    test "#{transport} native volume #{protocol}, writable=#{writable} matches the pinned byte helper",
         %{root: root, context: context} do
      transport = unquote(transport)
      protocol = unquote(protocol)
      writable = unquote(writable)
      identity = identity(transport, root, "volume")
      fixture = backend(root, transport, identity, protocol, false)
      endpoint = HTTPFixture.endpoint(fixture)

      input =
        Map.merge(endpoint, %{
          protocol: "volume_" <> protocol,
          pool: "pool+@ a",
          volume_type: "custom",
          name: "v+/n?é",
          project: "project +",
          target: "member +",
          writable: writable,
          read_initial: 3,
          payload: Base.encode64(@payload)
        })

      input =
        oracle_tls(input, identity)

      result = driver(root, input)
      assert Base.decode64!(result["initial"]) == @initial
      assert Base.decode64!(result["echo"]) == @payload
      assert result["write_count"] == byte_size(@payload)
      native = List.last(HTTPFixture.requests(fixture))
      assert native.headers["upgrade"] == protocol
      assert native.headers["connection"] == "Upgrade"
      client = client(fixture, context, identity)
      assert {:ok, channel} = open(client, protocol, writable)
      assert {:ok, @initial} = RawChannel.recv(channel)
      assert :ok = RawChannel.send_data(channel, @payload)
      assert {:ok, @payload} = RawChannel.recv(channel)
      assert :eof = RawChannel.recv(channel)
      assert :ok = RawChannel.close(channel)
      refute Process.alive?(channel.pid)
      actual = List.last(HTTPFixture.requests(fixture))

      assert :ok =
               WireComparison.compare(
                 WireComparison.request(native),
                 WireComparison.request(actual)
               )

      assert URI.decode_query(URI.parse(actual.target).query)["writable"] ==
               if(writable, do: "1", else: nil)

      assert actual.target =~ "/pool+@%20a/volumes/custom/v+%2Fn%3F%C3%A9/"
    end
  end

  for transport <- [:gen_tcp, :ssl], protocol <- ["sftp", "nbd"] do
    test "#{transport} volume #{protocol} preserves coalesced protocol bytes independently of the defective oracle",
         %{root: root, context: context} do
      transport = unquote(transport)
      protocol = unquote(protocol)
      identity = identity(transport, root, "coalesced")
      fixture = backend(root, transport, identity, protocol, true)
      assert {:ok, channel} = open(client(fixture, context, identity), protocol, true)
      assert {:ok, @initial} = RawChannel.recv(channel)
      assert :ok = RawChannel.send_data(channel, @payload)
      assert {:ok, @payload} = RawChannel.recv(channel)
      RawChannel.close(channel)
    end
  end

  test "volume preflight rejects unavailable extensions, invalid options and unready hosts without I/O",
       %{root: root, context: context} do
    connection = Connection.unix!(Path.join(root, "absent"), owner: :fixture)
    client = %Incus{connection: connection, context: context, server: %Server{api_extensions: []}}

    assert {:error, %Error{kind: :unsupported_extension, extension: "custom_volume_sftp"}} =
             Incus.volume_sftp(client, "pool", "custom", "v")

    assert {:error, %Error{kind: :unsupported_extension, extension: "storage_volume_nbd"}} =
             Incus.volume_nbd(client, "pool", "custom", "v")

    client = %{client | server: %Server{api_extensions: @extensions}}

    for opts <- [[writable: "yes"], [reuse: true], [writable: true, writable: false], %{}] do
      assert {:error, %Error{kind: :invalid_arguments}} =
               Incus.volume_nbd(client, "pool", "custom", "v", opts)
    end

    assert {:error, %Error{kind: :invalid_arguments}} =
             Incus.volume_sftp(client, "", "custom", "v")

    client = %{client | context: %{context | ready?: fn -> false end}}

    assert {:error, %Error{kind: :host_not_ready}} =
             Incus.volume_sftp(client, "pool", "custom", "v")
  end

  test "rejected volume upgrade retains native error and never retries", %{
    root: root,
    context: context
  } do
    for protocol <- ["sftp", "nbd"] do
      fixture =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(root, protocol),
           handler: fn _ ->
             %{
               status: 403,
               headers: %{"ETag" => "volume-tag"},
               body: %{type: "error", error_code: 777, error: "private-rejection"}
             }
           end},
          id: make_ref()
        )

      client = %Incus{
        connection: Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
        context: context,
        server: %Server{api_extensions: @extensions}
      }

      assert {:error, %Error{kind: :native, error_code: 777, response: response}} =
               open(client, protocol, false)

      assert response.etag == "volume-tag"
      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  defp backend(root, transport, identity, protocol, coalesced) do
    opts =
      if identity,
        do: [certfile: identity.certfile, keyfile: identity.keyfile],
        else: [path: Path.join(root, "s-#{System.unique_integer([:positive])}")]

    start_supervised!(
      {HTTPFixture,
       [
         transport: transport,
         handler: fn request ->
           if URI.parse(request.target).path == "/1.0" do
             %{
               status: 200,
               body: %{
                 type: "sync",
                 metadata: %{api_version: "1.0", api_extensions: @extensions, environment: %{}}
               }
             }
           else
             %{
               upgrade: fn adapter, socket ->
                 head =
                   "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: #{protocol}\r\n\r\n"

                 if coalesced do
                   :ok = adapter.send(socket, head <> @initial)
                 else
                   :ok = adapter.send(socket, head)
                   # Separate data delivery avoids the pinned rawConn bufio defect.
                   Process.sleep(150)
                   :ok = adapter.send(socket, @initial)
                 end

                 case adapter.recv(socket, byte_size(@payload), 3000) do
                   {:ok, payload} -> adapter.send(socket, payload)
                   {:error, :closed} -> :ok
                 end
               end
             }
           end
         end
       ] ++ opts},
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

  defp open(client, "sftp", _), do: Incus.volume_sftp(client, "pool+@ a", "custom", "v+/n?é")

  defp open(client, "nbd", writable),
    do: Incus.volume_nbd(client, "pool+@ a", "custom", "v+/n?é", writable: writable)

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
