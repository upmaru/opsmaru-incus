defmodule Opsmaru.Incus.GatewayFixtureTransferTest do
  # Task 1.3: transferred Macus upgrade fixtures with provenance, the Incus
  # v7.0.1 pin, and fake Unix/verified HTTPS denial/framing fixtures, without
  # Macus source or runtime.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Opsmaru.TestSupport.Gateway.{CowboyUpgradeHandler, NativeBackend}
  alias Opsmaru.TestSupport.TLSIdentity

  @manifest "priv/incus/gateway-transfer.json"
  @pin "13f3992766142d5087fff2e362cd2e1a75294fe8"

  describe "provenance" do
    test "transferred files match their recorded digests" do
      manifest = @manifest |> File.read!() |> Jason.decode!()
      assert manifest["source_repository"] == "https://github.com/upmaru/macus"
      assert manifest["source_revision"] =~ ~r/\A[0-9a-f]{40}\z/

      for file <- manifest["files"] do
        actual =
          :crypto.hash(:sha256, File.read!(file["destination"])) |> Base.encode16(case: :lower)

        assert actual == file["transferred_sha256"],
               "#{file["destination"]} differs from its recorded transfer; update the manifest deliberately"
      end
    end

    test "an altered copy is detected" do
      file = hd(Jason.decode!(File.read!(@manifest))["files"])
      altered = File.read!(file["destination"]) <> "\n# local edit\n"

      refute :crypto.hash(:sha256, altered) |> Base.encode16(case: :lower) ==
               file["transferred_sha256"]
    end

    # Opt-in: compare against a Macus checkout when one is explicitly supplied.
    @macus System.get_env("OPSMARU_INCUS_MACUS_CHECKOUT")
    @tag skip:
           if(@macus,
             do: false,
             else: "set OPSMARU_INCUS_MACUS_CHECKOUT to verify source digests"
           )
    test "source digests match the recorded Macus revision" do
      manifest = Jason.decode!(File.read!(@manifest))

      for file <- manifest["files"] do
        {bytes, 0} =
          System.cmd("git", [
            "-C",
            @macus,
            "show",
            "#{manifest["source_revision"]}:#{file["source"]}"
          ])

        assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
                 file["source_sha256"]
      end
    end

    test "the existing Incus v7.0.1 reference pin is unchanged" do
      assert Jason.decode!(File.read!("priv/incus/transfer.json"))["reference_revision"] == @pin
      assert File.read!("openspec/config.yaml") =~ @pin
      assert File.read!("priv/notices/INCUS-NOTICE.md") =~ @pin
    end
  end

  describe "transferred Cowboy protocol-switch fixture" do
    setup do
      root = Path.join(System.tmp_dir!(), "oig-up-#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)

      %{
        root: root,
        server: TLSIdentity.generate(root, "server", "localhost"),
        client: TLSIdentity.generate(root, "client", "fixture-client")
      }
    end

    for protocol <- ["sftp", "nbd"] do
      @tag protocol: protocol
      test "#{protocol}: coalesced bytes reach each peer exactly once over verified TLS",
           context do
        initial = :binary.copy(<<0, 255, 128, 13, 10, 0, 1>>, 2_000)
        {backend, port} = start_fixture(context, initial: initial)
        socket = connect(port, context)
        early = <<255, 0, 128, 1>>
        target = "/1.0/instances/fixture/#{context.protocol}?project=one+two&target=node%2Fa"
        :ok = :ssl.send(socket, [upgrade_request(target, context.protocol), early])
        {head, buffered} = read_head(socket)
        assert head =~ "HTTP/1.1 101 "
        assert receive_exact(socket, buffered, byte_size(initial <> early)) == initial <> early
        assert_receive {:backend_request, request}
        assert request =~ "GET #{target} HTTP/1.1"
        payload = :binary.copy(<<0, 255, 2, 128>>, 131_072)
        # Read the echo while sending: the fixture closes a peer whose writes
        # stay blocked for over a second, as a non-reading caller would.
        sender = Task.async(fn -> :ssl.send(socket, payload) end)
        assert receive_exact(socket, "", byte_size(payload)) == payload
        assert Task.await(sender) == :ok
        assert NativeBackend.accepted(backend) == 1
        :ssl.close(socket)
        assert_receive {:backend_closed, _}, 2_000
      end
    end

    @tag protocol: "sftp"
    test "an upgrade without the fixture identity is denied before Unix backend access",
         context do
      {backend, port} = start_fixture(context)
      socket = connect(port, context, false)
      :ok = :ssl.send(socket, upgrade_request("/1.0/instances/fixture/sftp", "sftp"))
      {head, _} = read_head(socket)
      assert head =~ "HTTP/1.1 403 "
      assert NativeBackend.accepted(backend) == 0
      :ssl.close(socket)
    end

    @tag protocol: "sftp"
    test "malformed upgrades and protocol mismatches never switch", context do
      {_backend, port} = start_fixture(context, reply_protocol: "nbd")

      for request <- [
            "GET /1.0/instances/fixture/sftp HTTP/1.1\r\nhost: localhost\r\nupgrade: sftp\r\n\r\n",
            "POST /1.0/instances/fixture/sftp HTTP/1.1\r\nhost: localhost\r\nconnection: upgrade\r\nupgrade: sftp\r\ncontent-length: 0\r\n\r\n"
          ] do
        socket = connect(port, context)
        :ok = :ssl.send(socket, request)
        {head, _} = read_head(socket)
        assert head =~ "HTTP/1.1 400 "
        :ssl.close(socket)
      end

      socket = connect(port, context)
      :ok = :ssl.send(socket, upgrade_request("/1.0/instances/fixture/sftp", "sftp"))
      {head, _} = read_head(socket)
      assert head =~ "HTTP/1.1 502 "
      refute_receive {:tunnel_started, _}, 50
      :ssl.close(socket)
    end

    @tag protocol: "nbd"
    test "backend half-close keeps the client-to-backend direction", context do
      {_backend, port} = start_fixture(context, initial: <<0, 1>>, half_close: true)
      socket = connect(port, context)
      :ok = :ssl.send(socket, upgrade_request("/1.0/instances/fixture/nbd", "nbd"))
      {head, buffered} = read_head(socket)
      assert head =~ "HTTP/1.1 101 "
      assert receive_exact(socket, buffered, 2) == <<0, 1>>
      :ok = :ssl.send(socket, <<9, 9, 9>>)
      assert_receive {:backend_bytes, <<9, 9, 9>>}, 2_000
      :ssl.close(socket)
    end

    @tag protocol: "nbd"
    test "ordinary traffic still reaches the host router on the same listener", context do
      {_backend, port} = start_fixture(context)
      socket = connect(port, context)

      :ok =
        :ssl.send(socket, "GET /runtime HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")

      capture_log(fn ->
        {head, _} = read_head(socket)
        assert head =~ "HTTP/1.1 200 "
      end)

      :ssl.close(socket)
    end
  end

  defp start_fixture(context, opts \\ []) do
    backend_opts =
      Map.merge(
        %{
          path: Path.join(context.root, "backend.sock"),
          protocol: context.protocol,
          observer: self(),
          initial: ""
        },
        Map.new(opts)
      )

    backend = start_supervised!({NativeBackend, backend_opts})
    handler_opts = %{path: backend_opts.path, certificate: context.client.der, observer: self()}

    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {"/1.0/instances/:name/sftp", CowboyUpgradeHandler, handler_opts},
           {"/1.0/instances/:name/nbd", CowboyUpgradeHandler, handler_opts},
           {:_, Plug.Cowboy.Handler, {Opsmaru.TestSupport.GatewayRouter, []}}
         ]}
      ])

    ref = {:gateway_upgrade_fixture, make_ref()}

    {:ok, _} =
      :cowboy.start_tls(
        ref,
        %{
          num_acceptors: 2,
          max_connections: 16,
          socket_opts: [
            ip: {127, 0, 0, 1},
            port: 0,
            certfile: String.to_charlist(context.server.certfile),
            keyfile: String.to_charlist(context.server.keyfile),
            cacertfile: String.to_charlist(context.client.cafile),
            verify: :verify_peer,
            fail_if_no_peer_cert: false,
            versions: [:"tlsv1.3"],
            alpn_preferred_protocols: ["http/1.1"]
          ]
        },
        %{env: %{dispatch: dispatch}, invalid_response_headers: :error_terminate}
      )

    on_exit(fn -> :cowboy.stop_listener(ref) end)
    {backend, :ranch.get_port(ref)}
  end

  defp connect(port, context, identity \\ true) do
    opts = [
      :binary,
      active: false,
      exit_on_close: false,
      verify: :verify_peer,
      cacertfile: String.to_charlist(context.server.cafile),
      server_name_indication: ~c"localhost",
      versions: [:"tlsv1.3"]
    ]

    opts =
      if identity,
        do:
          opts ++
            [
              certfile: String.to_charlist(context.client.certfile),
              keyfile: String.to_charlist(context.client.keyfile)
            ],
        else: opts

    {:ok, socket} = :ssl.connect(~c"localhost", port, opts, 2_000)
    socket
  end

  defp upgrade_request(target, protocol),
    do: [
      "GET ",
      target,
      " HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: ",
      protocol,
      "\r\n\r\n"
    ]

  defp read_head(socket, bytes \\ "") do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        {head, body}

      [_] ->
        {:ok, next} = :ssl.recv(socket, 0, 2_000)
        read_head(socket, bytes <> next)
    end
  end

  defp receive_exact(_socket, bytes, size) when byte_size(bytes) == size, do: bytes

  defp receive_exact(socket, bytes, size) when byte_size(bytes) < size do
    {:ok, next} = :ssl.recv(socket, size - byte_size(bytes), 2_000)
    receive_exact(socket, bytes <> next, size)
  end
end
