defmodule Opsmaru.Incus.NetworkModelsReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Error, Model, NetworkModels}
  @driver Path.expand("../../.integration/incus-network-models", __DIR__)
  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, code} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./networkmodels"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert code == 0, out
    :ok
  end

  for type <-
        ~w(NetworkACLRule NetworkAddressSet NetworkForwardPort NetworkForwardPut NetworkForwardsPost NetworkLoadBalancerBackend NetworkLoadBalancerPort NetworkLoadBalancerPut) do
    test "#{type} populated, empty and null models match the unchanged native Normalise helper" do
      type = unquote(type)

      for data <- [%{}, populated(type), null_fields(type)] do
        expected = native(type, data)
        assert {:ok, model} = Model.decode(type, data)
        assert {:ok, result} = NetworkModels.normalise(model)
        assert result.type == type
        assert result.data == expected
        assert model.data == data
        assert {:ok, ^result} = NetworkModels.normalise(result)
      end
    end
  end

  test "native IPv4/IPv6 canonicalization and invalid address preservation match Go" do
    for address <- [
          "192.0.2.1",
          "001.2.3.4",
          "127.1",
          "3232235777",
          "",
          "invalid",
          " 2001:db8::1 ",
          "2001:0DB8:0000:0000:0001:0000:0000:0001",
          "2001:db8:0:1:0:0:0:1",
          "::",
          "::1",
          "::ffff:192.0.2.128",
          "::ffff:c000:0280",
          "::192.0.2.128",
          "fe80::1%en0",
          "[::1]",
          "192.0.2.1/24",
          "::ffff:001.2.3.4"
        ] do
      for type <- ["NetworkForwardPort", "NetworkForwardsPost", "NetworkForwardPut"] do
        key = if type == "NetworkForwardsPost", do: "listen_address", else: "target_address"

        data =
          if type == "NetworkForwardPut",
            do: %{"config" => %{key => address}},
            else: %{key => address}

        assert {:ok, model} = Model.decode(type, data)
        assert {:ok, result} = NetworkModels.normalise(model)
        assert result.data == native(type, data)
      end
    end
  end

  test "Go Unicode whitespace, empty list entries and deliberate untrimmed fields are preserved" do
    space =
      "\t\n\v\f\r \u0085\u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u2028\u2029\u202F\u205F\u3000"

    for type <- NetworkModels.types() do
      data = populated(type)
      data = Map.put(data, "description", space <> "keep\u200B\uFEFF" <> space)
      assert {:ok, model} = Model.decode(type, data)
      assert {:ok, result} = NetworkModels.normalise(model)
      assert result.data == native(type, data)
    end

    data = %{
      "description" => "  trim  ",
      "protocol" => " TCP ",
      "listen_port" => " 80 , , 81- 90 ,",
      "target_backend" => [" keep spaces "]
    }

    assert {:ok, model} = Model.decode("NetworkLoadBalancerPort", data)
    assert {:ok, result} = NetworkModels.normalise(model)
    assert result.data == native(model.type, data)
    assert result.data["protocol"] == "TCP"
    assert result.data["listen_port"] == "80,,81- 90,"
    assert result.data["target_backend"] == [" keep spaces "]
  end

  test "lossless decoding and native typed projection remain explicit and database-free" do
    data =
      Map.put(populated("NetworkForwardPort"), "future_native_field", %{"private" => "retained"})

    assert {:ok, model} = Model.decode("NetworkForwardPort", data)
    assert model.data == data
    assert {:ok, result} = NetworkModels.normalise(model)
    refute Map.has_key?(result.data, "future_native_field")
    assert result.data == native(model.type, data)
    refute inspect(result) =~ "retained"
    refute Process.whereis(Opsmaru.Repo)
    refute Process.whereis(OpsmaruWeb.Endpoint)
  end

  test "invalid types and oversized inputs fail visibly" do
    assert {:error, %Error{kind: :unsupported_model_helper}} =
             NetworkModels.normalise(%Model{type: "Instance", data: %{}})

    for data <- [
          %{"ports" => "wrong"},
          %{"description" => String.duplicate("x", 1_048_577)},
          %{"description" => 1},
          %{"ports" => [%{"protocol" => []}]}
        ] do
      assert {:error, %Error{kind: :invalid_network_model}} =
               NetworkModels.normalise(%Model{type: "NetworkForwardPut", data: data})
    end
  end

  defp native(type, data) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{type: type, body: data}) <> "\n")
    out = collect(port, "")
    Jason.decode!(out)
  end

  defp collect(port, out) do
    receive do
      {^port, {:data, bytes}} -> collect(port, out <> bytes)
      {^port, {:exit_status, 0}} -> out
      {^port, {:exit_status, code}} -> flunk("native helper exited #{code}")
    after
      5000 ->
        Port.close(port)
        flunk("native helper deadline")
    end
  end

  defp null_fields(type) do
    populated(type) |> Map.new(fn {key, _} -> {key, nil} end)
  end

  defp populated("NetworkACLRule"),
    do: %{
      "action" => " allow ",
      "source" => " @internal , @external ",
      "destination" => " 192.0.2.1 , 192.0.2.2 ",
      "protocol" => " TCP ",
      "source_port" => " 80 , , 90 ",
      "destination_port" => " 443 ",
      "icmp_type" => " 8 ",
      "icmp_code" => " 0 ",
      "description" => " keep ",
      "state" => " enabled "
    }

  defp populated("NetworkAddressSet"),
    do: %{
      "name" => " name ",
      "addresses" => [" 192.0.2.1 ", " "],
      "description" => " untrimmed ",
      "config" => %{" user.key " => " value "},
      "used_by" => [" keep "],
      "project" => " untrimmed "
    }

  defp populated("NetworkForwardPort"),
    do: %{
      "description" => " keep ",
      "protocol" => " TCP ",
      "listen_port" => " 80 , 81-90 ",
      "target_port" => " 8080 , ",
      "target_address" => " 2001:0DB8::1 ",
      "snat" => true
    }

  defp populated("NetworkForwardPut"),
    do: %{
      "description" => " keep ",
      "config" => %{"target_address" => "2001:0DB8::2", "untouched" => " keep "},
      "ports" => [populated("NetworkForwardPort"), %{}]
    }

  defp populated("NetworkForwardsPost"),
    do: Map.put(populated("NetworkForwardPut"), "listen_address", "2001:0DB8::3")

  defp populated("NetworkLoadBalancerBackend"),
    do: %{
      "name" => " untrimmed ",
      "description" => " keep ",
      "target_port" => " 8080 , 9090 ",
      "target_address" => " ::ffff:192.0.2.128 "
    }

  defp populated("NetworkLoadBalancerPort"),
    do: %{
      "description" => " keep ",
      "protocol" => " TCP ",
      "listen_port" => " 80 , 443 ",
      "target_backend" => [" untrimmed "]
    }

  defp populated("NetworkLoadBalancerPut"),
    do: %{
      "description" => " keep ",
      "config" => %{"untouched" => " keep "},
      "backends" => [populated("NetworkLoadBalancerBackend"), %{}],
      "ports" => [populated("NetworkLoadBalancerPort"), %{}]
    }
end
