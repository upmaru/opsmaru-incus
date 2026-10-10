defmodule Opsmaru.Incus.NativeUpgradeReferenceTest do
  @moduledoc """
  Negative oracle evidence, not Opsmaru stream implementation or acceptance.
  Demonstrates the pinned upstream rawConn losing bufio-prefetched bytes.
  """
  use ExUnit.Case, async: false
  @driver Path.expand("../../.integration/incus-reference-driver", __DIR__)

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    :ok
  end

  for protocol <- ["sftp", "nbd"] do
    test "#{protocol}: official-client coalesced handshake loses bytes while separate delivery works" do
      protocol = unquote(protocol)
      root = Path.join(System.tmp_dir!(), "op-upgrade-#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)

      for coalesced <- [false, true] do
        path = Path.join(root, "socket-#{coalesced}")

        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

        on_exit(fn -> :gen_tcp.close(listener) end)
        parent = self()

        fixture =
          spawn_link(fn ->
            serve_discovery(listener)
            serve_upgrade(listener, protocol, coalesced, parent)
          end)

        on_exit(fn -> if Process.alive?(fixture), do: Process.exit(fixture, :kill) end)
        payload = <<255, 0, 128, 10>>

        input = %{
          socket: path,
          protocol: protocol,
          payload: Base.encode64(payload),
          read_initial: 3,
          half_close: true
        }

        file = Path.join(root, "input-#{coalesced}.json")
        File.write!(file, Jason.encode!(input))
        File.chmod!(file, 0o600)
        {output, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
        assert_receive {:upgrade_request, request}, 5_000
        assert request =~ "GET /1.0/instances/fixture/#{protocol} HTTP/1.1"
        assert request =~ "Upgrade: #{protocol}"

        if coalesced do
          # The server sent HTTP 101 and 3 binary bytes in one write, followed
          # by a write-half-close. The oracle returns EOF before those bytes.
          assert status != 0
          assert String.trim(output) == "EOF"
        else
          assert status == 0, output
          result = Jason.decode!(output)
          assert Base.decode64!(result["initial"]) == <<0, 255, 128>>
          assert result["read_eof"] == true
          assert result["write_count"] == byte_size(payload)
          assert_receive {:upgrade_payload, ^payload}, 5_000
        end

        :gen_tcp.close(listener)
      end
    end
  end

  defp serve_discovery(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    read_head(socket, "")

    body =
      Jason.encode!(%{
        type: "sync",
        status_code: 200,
        metadata: %{api_version: "1.0", api_extensions: ["instance_nbd"], environment: %{}}
      })

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\nConnection: close\r\n\r\n",
        body
      ])

    :gen_tcp.close(socket)
  end

  defp serve_upgrade(listener, protocol, coalesced, parent) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    request = read_head(socket, "")
    send(parent, {:upgrade_request, request})

    head =
      "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: #{protocol}\r\n\r\n"

    initial = <<0, 255, 128>>

    if coalesced do
      :ok = :gen_tcp.send(socket, head <> initial)
    else
      :ok = :gen_tcp.send(socket, head)
      Process.sleep(150)
      :ok = :gen_tcp.send(socket, initial)
    end

    :ok = :gen_tcp.shutdown(socket, :write)

    case :gen_tcp.recv(socket, 4, 3_000) do
      {:ok, payload} -> send(parent, {:upgrade_payload, payload})
      {:error, :closed} -> :ok
    end

    :gen_tcp.close(socket)
  end

  defp read_head(socket, bytes) do
    if byte_size(bytes) > 65_536, do: raise("fixture header limit")

    if :binary.match(bytes, "\r\n\r\n") == :nomatch do
      {:ok, next} = :gen_tcp.recv(socket, 0, 5_000)
      read_head(socket, bytes <> next)
    else
      bytes
    end
  end
end
