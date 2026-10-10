defmodule Opsmaru.Incus.RawChannelTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, RawChannel, Server}

  setup do
    root = Path.join(System.tmp_dir!(), "op-raw-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    %{root: root, context: context}
  end

  for protocol <- ["sftp", "nbd"] do
    test "#{protocol} preserves coalesced bytes and writes after backend half-close", %{
      root: root,
      context: context
    } do
      protocol = unquote(protocol)
      initial = <<0, 255, 128, 13, 10, 0>>
      {client, fixture} = fixture(root, context, protocol, initial, true)

      {:ok, channel} =
        if protocol == "sftp",
          do: Incus.sftp(client, "fixture"),
          else: Incus.nbd(client, "fixture", reuse: true)

      assert {:ok, ^initial} = RawChannel.recv(channel)
      assert :eof = RawChannel.recv(channel)
      bytes = <<255, 0, 128, 42>>
      assert :ok = RawChannel.send_data(channel, bytes)
      assert_receive {:request, request}, 5_000
      assert request =~ "Upgrade: #{protocol}"
      if protocol == "nbd", do: assert(request =~ "reuse=1")
      assert_receive {:payload, ^bytes}, 5_000
      assert :ok = RawChannel.close(channel)
      refute Process.alive?(channel.pid)
      Process.exit(fixture, :kill)
    end
  end

  test "duplex bytes, explicit local close and lifetime cleanup stay bounded", %{
    root: root,
    context: context
  } do
    {client, fixture} = fixture(root, context, "sftp", <<0, 255, 128>>, false)
    {:ok, channel} = Incus.sftp(client, "fixture")
    assert {:ok, <<0, 255, 128>>} = RawChannel.recv(channel)
    assert :ok = RawChannel.send_data(channel, <<255, 0, 128, 42>>)
    assert {:ok, <<255, 0, 128, 42>>} = RawChannel.recv(channel)
    assert :ok = RawChannel.shutdown_write(channel)
    assert :ok = RawChannel.close(channel)
    Process.exit(fixture, :kill)

    {client, fixture} = fixture(root, context, "sftp", "", false)
    client = %{client | connection: %{client.connection | stream_timeout: 50}}
    {:ok, channel} = Incus.sftp(client, "fixture")
    ref = channel.ref
    assert_receive {^ref, :error, %Error{kind: :deadline}}, 1_000
    refute Process.alive?(channel.pid)
    Process.exit(fixture, :kill)
  end

  test "bad upgrade framing fails, readiness and extension failures never open a backend", %{
    root: root,
    context: context
  } do
    {client, fixture} = fixture(root, context, "websocket", "", false)
    assert {:error, %Error{kind: :upgrade_failed}} = Incus.sftp(client, "fixture")
    Process.exit(fixture, :kill)
    client = %{client | context: %{context | ready?: fn -> false end}}
    assert {:error, %Error{kind: :host_not_ready}} = Incus.sftp(client, "fixture")

    assert {:error, %Error{kind: :unsupported_extension}} =
             Incus.nbd(%{client | server: %Server{api_extensions: []}}, "fixture")
  end

  defp fixture(root, context, protocol, initial, half_close) do
    path = Path.join(root, "s-#{System.unique_integer([:positive])}")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    fixture =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, {:request, request})

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: ",
            protocol,
            "\r\n\r\n",
            initial
          ])

        if half_close, do: :gen_tcp.shutdown(socket, :write)

        case :gen_tcp.recv(socket, 4, 5_000) do
          {:ok, payload} ->
            send(parent, {:payload, payload})
            if not half_close, do: :gen_tcp.send(socket, payload)

          _ ->
            :ok
        end

        receive do
          :close -> :ok
        after
          5_000 -> :ok
        end

        :gen_tcp.close(socket)
      end)

    on_exit(fn -> if Process.alive?(fixture), do: Process.exit(fixture, :kill) end)

    client = %Incus{
      connection: Connection.unix!(path, owner: :fixture),
      context: context,
      server: %Server{api_extensions: ["instance_nbd"]}
    }

    {client, fixture}
  end
end
