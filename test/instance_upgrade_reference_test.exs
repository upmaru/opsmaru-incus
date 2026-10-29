defmodule Opsmaru.Incus.InstanceUpgradeReferenceTest do
  @moduledoc """
  S08 instance raw upgrades compared with the unchanged pinned `GetInstanceFileSFTPConn`
  and `GetInstanceNBDConn`. The backend delivers data separately from the 101 response
  so the pinned rawConn prefetch defect does not hide bytes; coalesced delivery is
  covered independently in `raw_channel_test.exs` and `tls_stream_test.exs`.
  """
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, RawChannel, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WireComparison}
  @driver Path.expand("../.integration/incus-instance-upgrade-driver", __DIR__)
  @initial <<0, 255, 128>>
  @payload <<255, 0, 128, 13, 10>>
  @extensions ["instance_nbd", "custom_volume_sftp", "storage_volume_nbd"]
  # The pinned helpers send any name; the server answers natively.
  @names ["fixture", "", "i+/n?é#%;, $&", String.duplicate("a", 1500)]

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
    root = Path.join(System.tmp_dir!(), "op-iup-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    }
  end

  for transport <- [:gen_tcp, :ssl],
      {protocol, reuse} <- [{"sftp", false}, {"nbd", false}, {"nbd", true}] do
    test "#{transport} instance #{protocol}, reuse=#{reuse} matches the pinned byte helper for every name",
         %{root: root, context: context} do
      transport = unquote(transport)
      protocol = unquote(protocol)
      reuse = unquote(reuse)
      identity = identity(transport, root)
      fixture = backend(root, transport, identity, protocol, :echo)
      client = client(fixture, context, identity)

      for name <- @names do
        result = driver(root, input(fixture, identity, protocol, name, reuse: reuse))
        assert Base.decode64!(result["initial"]) == @initial
        assert Base.decode64!(result["echo"]) == @payload
        assert result["write_count"] == byte_size(@payload)
        native = List.last(HTTPFixture.requests(fixture))

        assert {:ok, channel} = open(client, protocol, name, reuse)
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

        for header <- ["upgrade", "connection"],
            do: assert(actual.headers[header] == native.headers[header])

        assert actual.headers["upgrade"] == protocol

        assert URI.parse(actual.target).path ==
                 "/1.0/instances/" <> escape(name) <> "/" <> protocol

        assert URI.decode_query(URI.parse(actual.target).query) ==
                 Map.merge(
                   %{"project" => "project +", "target" => "member +"},
                   if(reuse, do: %{"reuse" => "1"}, else: %{})
                 )
      end
    end
  end

  for transport <- [:gen_tcp, :ssl], protocol <- ["sftp", "nbd"] do
    test "#{transport} instance #{protocol} backend half-close matches the pinned connection",
         %{root: root, context: context} do
      transport = unquote(transport)
      protocol = unquote(protocol)
      identity = identity(transport, root)
      fixture = backend(root, transport, identity, protocol, {:half_close, self()})

      result =
        driver(root, Map.put(input(fixture, identity, protocol, "fixture"), :half_close, true))

      assert Base.decode64!(result["initial"]) == @initial
      assert result["read_eof"] == true
      assert result["write_count"] == byte_size(@payload)
      assert_receive {:payload, @payload}, 5_000
      native = List.last(HTTPFixture.requests(fixture))

      assert {:ok, channel} = open(client(fixture, context, identity), protocol, "fixture", false)
      assert {:ok, @initial} = RawChannel.recv(channel)
      assert :eof = RawChannel.recv(channel)

      write_after_half_close(transport, channel)
      assert :ok = RawChannel.close(channel)
      actual = List.last(HTTPFixture.requests(fixture))

      assert :ok =
               WireComparison.compare(
                 WireComparison.request(native),
                 WireComparison.request(actual)
               )
    end
  end

  for transport <- [:gen_tcp, :ssl], protocol <- ["sftp", "nbd"] do
    test "#{transport} instance #{protocol} native rejection matches the pinned error and is sent once",
         %{root: root, context: context} do
      transport = unquote(transport)
      protocol = unquote(protocol)
      identity = identity(transport, root)
      fixture = backend(root, transport, identity, protocol, :reject)

      result =
        driver(root, Map.put(input(fixture, identity, protocol, ""), :report_error, true))

      assert result["error_status"] == 404
      assert result["error"] == "not-found-#{protocol}"
      assert [%{method: "GET"}] = upgrades(fixture)

      assert {:error, %Error{kind: :native, http_status: 404, error_code: 404, message: message}} =
               open(client(fixture, context, identity), protocol, "", false)

      assert message == result["error"]
      assert [native, actual] = upgrades(fixture)

      assert :ok =
               WireComparison.compare(
                 WireComparison.request(native),
                 WireComparison.request(actual)
               )
    end
  end

  test "names are escaped and sent like the pinned helpers; only typed options and pinned guards are local",
       %{root: root, context: context} do
    fixture = backend(root, :gen_tcp, nil, "sftp", :echo)
    client = client(fixture, context, nil)

    for open <- [
          fn -> Incus.sftp(client, <<255, 0, ?/>>) end,
          fn -> Incus.volume_sftp(client, "", <<255>>, "v/n") end
        ] do
      assert {:ok, channel} = open.()
      RawChannel.close(channel)
    end

    assert [instance, volume] = upgrades(fixture)
    assert URI.parse(instance.target).path == "/1.0/instances/%FF%00%2F/sftp"
    assert URI.parse(volume.target).path == "/1.0/storage-pools//volumes/%FF/v%2Fn/sftp"

    for call <- [
          fn -> Incus.sftp(client, :fixture) end,
          fn -> Incus.nbd(client, "fixture", reuse: "yes") end,
          fn -> Incus.nbd(client, "fixture", writable: true) end,
          fn -> Incus.volume_nbd(client, "pool", "custom", nil) end,
          fn -> Incus.volume_nbd(client, "pool", "custom", "v", reuse: true) end
        ] do
      assert {:error, %Error{kind: :invalid_arguments}} = call.()
    end

    client = %{client | server: %Server{api_extensions: []}}

    for {call, extension} <- [
          {fn -> Incus.nbd(client, "") end, "instance_nbd"},
          {fn -> Incus.volume_sftp(client, "", "", "") end, "custom_volume_sftp"},
          {fn -> Incus.volume_nbd(client, "", "", "") end, "storage_volume_nbd"}
        ] do
      assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} = call.()
    end

    # The pinned instance SFTP helper has no extension guard.
    assert {:ok, channel} = Incus.sftp(client, "")
    RawChannel.close(channel)
    assert length(upgrades(fixture)) == 3
  end

  defp write_after_half_close(:gen_tcp, channel) do
    assert :ok = RawChannel.send_data(channel, @payload)
    assert_receive {:payload, @payload}, 5_000
  end

  # Approved difference: OTP TLS cannot write after the peer's close_notify. The write is
  # refused explicitly, never sent or lost silently; incusd never half-closes.
  defp write_after_half_close(:ssl, channel) do
    assert {:error, %Error{kind: :write_closed}} = RawChannel.send_data(channel, @payload)
    assert :eof = RawChannel.recv(channel)
    refute_receive {:payload, _}, 200
  end

  defp backend(root, transport, identity, protocol, mode) do
    opts =
      if identity,
        do: [certfile: identity.certfile, keyfile: identity.keyfile],
        else: [path: Path.join(root, "s-#{System.unique_integer([:positive])}")]

    start_supervised!(
      {HTTPFixture,
       [
         transport: transport,
         handler: fn request ->
           cond do
             URI.parse(request.target).path == "/1.0" ->
               %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{api_version: "1.0", api_extensions: @extensions, environment: %{}}
                 }
               }

             mode == :reject ->
               %{
                 status: 404,
                 body: %{type: "error", error_code: 404, error: "not-found-#{protocol}"}
               }

             true ->
               %{upgrade: &serve(&1, &2, protocol, mode)}
           end
         end
       ] ++ opts},
      id: make_ref()
    )
  end

  defp serve(adapter, socket, protocol, mode) do
    :ok =
      adapter.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: #{protocol}\r\n\r\n"
      )

    # Separate data delivery avoids the pinned rawConn bufio defect.
    Process.sleep(150)
    :ok = adapter.send(socket, @initial)

    case mode do
      :echo ->
        case adapter.recv(socket, byte_size(@payload), 3000) do
          {:ok, payload} -> adapter.send(socket, payload)
          {:error, _} -> :ok
        end

      {:half_close, parent} ->
        Process.sleep(50)
        :ok = adapter.shutdown(socket, :write)

        case adapter.recv(socket, byte_size(@payload), 3000) do
          {:ok, payload} -> send(parent, {:payload, payload})
          {:error, _} -> :ok
        end
    end
  end

  defp client(fixture, context, identity) do
    endpoint = HTTPFixture.endpoint(fixture)
    routing = [owner: :fixture, project: "project +", member: "member +"]

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            routing ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, routing)

    {:ok, client} = Incus.connect(connection, context)
    client
  end

  defp input(fixture, identity, protocol, name, opts \\ []) do
    input =
      Map.merge(HTTPFixture.endpoint(fixture), %{
        protocol: protocol,
        instance: name,
        reuse: Keyword.get(opts, :reuse, false),
        project: "project +",
        target: "member +",
        read_initial: byte_size(@initial),
        payload: Base.encode64(@payload)
      })

    if identity, do: Map.put(input, :server_cert, File.read!(identity.certfile)), else: input
  end

  defp open(client, "sftp", name, _), do: Incus.sftp(client, name)
  defp open(client, "nbd", name, reuse), do: Incus.nbd(client, name, reuse: reuse)

  defp upgrades(fixture),
    do: Enum.reject(HTTPFixture.requests(fixture), &(URI.parse(&1.target).path == "/1.0"))

  # Go's url.PathEscape for one segment.
  defp escape(name),
    do: URI.encode(name, &(URI.char_unreserved?(&1) or &1 in ~c"$&+:=@"))

  defp identity(:gen_tcp, _), do: nil
  defp identity(:ssl, root), do: TLSIdentity.generate(root, "instance", "localhost")

  defp driver(root, input) do
    file = Path.join(root, "input.json")
    File.write!(file, Jason.encode!(input))
    File.chmod!(file, 0o600)
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end
end
