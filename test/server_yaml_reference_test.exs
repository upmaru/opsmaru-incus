defmodule Opsmaru.Incus.ServerYamlReferenceTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.{Error, Model, Projections}
  @moduletag timeout: 120_000
  @driver Path.expand("../../.integration/server-yaml-driver", __DIR__)

  @realistic %{
    "config" => %{
      "core.https_address" => ":8443",
      "core.trust_password" => "secret",
      "images.auto_update_interval" => "6",
      "cluster.https_address" => "",
      "user.b10" => "y",
      "user.b9" => "z"
    },
    "api_extensions" => ["storage_zfs_remove_snapshots", "container_host_shutdown_timeout"],
    "api_status" => "stable",
    "api_version" => "1.0",
    "auth" => "trusted",
    "public" => false,
    "auth_methods" => ["tls", "oidc"],
    "auth_user_name" => "zack",
    "auth_user_method" => "unix",
    "environment" => %{
      "addresses" => ["10.0.0.1:8443", "[::1]:8443"],
      "architectures" => ["x86_64", "i686"],
      "certificate" => "-----BEGIN CERTIFICATE-----",
      "certificate_fingerprint" => "a1b2c3",
      "driver" => "lxc | qemu",
      "driver_version" => "6.0.0 | 9.0.2",
      "firewall" => "nftables",
      "kernel" => "Linux",
      "kernel_architecture" => "x86_64",
      "kernel_features" => %{"idmapped_mounts" => "true", "shiftfs" => "false"},
      "kernel_version" => "6.8.0-45-generic",
      "lxc_features" => %{"cgroup2" => "true", "mount_injection_file" => "true"},
      "os_name" => "Ubuntu",
      "os_version" => "24.04",
      "project" => "default",
      "server" => "incus",
      "server_clustered" => false,
      "server_event_mode" => "full-mesh",
      "server_name" => "node1",
      "server_pid" => 1234,
      "server_version" => "6.6",
      "storage" => "zfs | btrfs",
      "storage_version" => "2.2.2 | 6.6.3",
      "storage_supported_drivers" => [
        %{"Name" => "btrfs", "Version" => "6.6.3", "Remote" => false},
        %{"Name" => "ceph", "Version" => "17.2.7", "Remote" => true}
      ]
    }
  }

  @atoms ~w(x abc 1 0 -1 1.0 6.6 24.04 true false True y n yes no on off ~ null << 1:20 -1:30.5 .inf .nan 0x1F 0755 1_000 1e3) ++
           [
             "",
             " ",
             " a",
             "a ",
             "a: b",
             "a:b",
             "a #b",
             "a#b",
             "#a",
             "- a",
             "-a",
             "-",
             "?",
             "? a",
             ":",
             ":a",
             "a:"
           ] ++
           [
             "---",
             "...",
             "--x",
             "[::1]:8443",
             "{x}",
             "&a",
             "*a",
             "!a",
             "|a",
             ">a",
             "%a",
             "@a",
             "`a",
             "'a",
             "\"a"
           ] ++
           [
             "it's",
             "a\"b",
             "a\\b",
             "héllo",
             "日本",
             "a,b",
             "a, b",
             "x?y",
             "lxc | qemu",
             "https://x:1/a?b=c",
             "a  b"
           ]

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./serveryaml"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "realistic, empty and null servers render the exact native bytes" do
    servers = [
      @realistic,
      %{},
      %{"config" => nil, "api_extensions" => [], "environment" => %{"addresses" => nil}}
    ]

    for {server, native} <- Enum.zip(servers, oracle(servers)) do
      assert native["accepted"]
      assert Projections.filtered_server_yaml(server) == {:ok, native["yaml"]}
    end

    {:ok, yaml} = Projections.filtered_server_yaml(@realistic)
    assert yaml =~ "api_extensions_count: 2\napi_status: stable\n"
    assert yaml =~ "core.trust_password: SENSITIVE\n"
    {:ok, model} = Model.decode("Server", @realistic)
    assert Projections.filtered_server_yaml(model) == {:ok, yaml}
  end

  test "every one- and two-atom string satisfies the byte contract as key and value" do
    strings = Enum.uniq(@atoms ++ for(a <- @atoms, b <- @atoms, do: a <> b))

    servers =
      Enum.flat_map(strings, fn s ->
        [%{"config" => %{"k" => s}}, %{"environment" => %{"kernel_features" => %{s => "v"}}}]
      end)

    rendered = assert_contract(servers)
    assert rendered > length(servers) * 0.95
  end

  test "randomized servers satisfy the byte contract" do
    :rand.seed(:exsss, {1, 2, 3})
    servers = for _ <- 1..300, do: random_server()
    assert assert_contract(servers) > 200
  end

  test "recorded differences: native renders these, the subset rejects them" do
    servers =
      for value <- ["a\tb", "line\nbreak", "x\u0085y", "2024-01-01", "1e31_000"],
          do: %{"config" => %{"k" => value}}

    servers = servers ++ [%{"config" => %{String.duplicate("k", 129) => "v"}}]

    for {server, native} <- Enum.zip(servers, oracle(servers)) do
      assert native["accepted"]
      assert {:error, %Error{}} = Projections.filtered_server_yaml(server)
    end
  end

  test "invalid input is rejected without raising, as natively" do
    assert {:error, %Error{}} = Projections.filtered_server_yaml("server")
    assert {:error, %Error{}} = Projections.filtered_server_yaml(1)

    invalid = [
      %{"public" => "yes"},
      %{"environment" => %{"server_pid" => 1.5}},
      %{"config" => %{"k" => [1]}},
      %{"auth_methods" => "tls"}
    ]

    for {server, native} <- Enum.zip(invalid, oracle(invalid)) do
      refute native["accepted"]
      assert {:error, %Error{}} = Projections.filtered_server_yaml(server)
    end
  end

  defp assert_contract(servers) do
    servers
    |> Enum.zip(oracle(servers))
    |> Enum.count(fn {server, native} ->
      case Projections.filtered_server_yaml(server) do
        {:ok, yaml} ->
          assert native["accepted"], "rendered what native rejects: #{inspect(server)}"
          assert yaml == native["yaml"], "bytes differ from native: #{inspect(server)}"
          true

        {:error, %Error{}} ->
          false
      end
    end)
  end

  defp random_server do
    str = fn -> Enum.map_join(1..:rand.uniform(2), "", fn _ -> Enum.random(@atoms) end) end

    key = fn ->
      Enum.random([
        "user.k#{:rand.uniform(120)}",
        "a#{Enum.random(~w(0 00 01 10 9 007))}b",
        "B#{:rand.uniform(9)}",
        "x-01",
        str.()
      ])
    end

    map = fn -> Map.new(1..:rand.uniform(4), fn _ -> {key.(), str.()} end) end

    %{
      "config" => map.(),
      "api_extensions" => Enum.map(1..:rand.uniform(3), fn _ -> str.() end),
      "api_status" => str.(),
      "public" => Enum.random([true, false]),
      "auth_methods" => Enum.map(1..:rand.uniform(2), fn _ -> str.() end),
      "environment" => %{
        "addresses" => [str.(), str.()],
        "kernel_features" => map.(),
        "server_pid" => :rand.uniform(100_000),
        "os_version" => str.(),
        "storage_supported_drivers" => [
          %{"Name" => str.(), "Version" => str.(), "Remote" => true}
        ]
      }
    }
  end

  defp oracle(servers) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{cases: servers}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)["results"]

      {^port, {:exit_status, status}} ->
        flunk("native server YAML oracle failed #{status}: #{data}")
    after
      30_000 ->
        Port.close(port)
        flunk("native server YAML oracle deadline")
    end
  end
end
