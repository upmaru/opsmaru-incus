defmodule Opsmaru.Incus.NativeConfigReferenceTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.Model
  alias Opsmaru.Incus.NativeConfig
  @driver Path.expand("../../.integration/incus-configmaps-driver", __DIR__)

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./configmaps"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  for type <- ["ConfigMap", "DevicesMap"] do
    test "#{type} coerces native scalars and JSON float64 precision exactly", %{} do
      type = unquote(type)

      for value <- [
            nil,
            "",
            "native+/é",
            true,
            false,
            0,
            -1,
            7.0,
            -0.0,
            1.25,
            -2.75,
            0.00001,
            0.00012,
            1.234_567_8e6,
            -1.234_567_8e6,
            9_007_199_254_740_993,
            9_223_372_036_854_775_807,
            -9_223_372_036_854_775_808,
            1.0e20,
            1.234e-20,
            -1.234e20,
            1.797_693_134_862_315_7e308
          ] do
        data = if type == "ConfigMap", do: %{"key" => value}, else: %{"eth0" => %{"key" => value}}
        assert {:ok, native} = NativeConfig.from_json(type, Jason.encode!(data))

        assert native == oracle(type, data)["value"],
               "native mismatch for #{type}, #{inspect(value)}"
      end
    end

    test "#{type} null/empty updates and existing-key merge match native decode", %{} do
      type = unquote(type)

      existing =
        if type == "ConfigMap",
          do: %{"kept" => "old", "change" => "old"},
          else: %{"eth0" => %{"kept" => "old", "change" => "old"}}

      update =
        if type == "ConfigMap",
          do: %{"change" => true, "new" => 7},
          else: %{"eth0" => %{"change" => true}, "root" => %{"new" => 7}}

      for data <- [nil, %{}, update] do
        assert {:ok, native} = NativeConfig.from_json(type, Jason.encode!(data), existing)
        assert native == oracle(type, data, existing)["value"]
      end

      assert {:ok, nil} = NativeConfig.from_json(type, "null")
      assert {:ok, %{}} = NativeConfig.from_json(type, "{}")
    end

    test "#{type} rejects invalid containers and scalar shapes as the native decoder does", %{} do
      type = unquote(type)

      bad =
        if type == "ConfigMap",
          do: [%{"key" => []}, %{"key" => %{}}, [], true, "scalar"],
          else: [
            %{"eth0" => nil},
            %{"eth0" => []},
            %{"eth0" => true},
            %{"eth0" => %{"key" => []}},
            [],
            true
          ]

      for data <- bad do
        assert oracle(type, data)["error"] == true

        assert {:error, %Error{kind: :invalid_native_config}} =
                 NativeConfig.from_json(type, Jason.encode!(data))
      end
    end
  end

  test "malformed, oversized and invalid existing values fail without exposing config" do
    for {type, json, existing} <- [
          {"unknown", "{}", nil},
          {"ConfigMap", "{", nil},
          {"ConfigMap", String.duplicate(" ", 1_048_577), nil},
          {"ConfigMap", "{}", %{"private" => 7}},
          {"DevicesMap", "{}", %{"device" => []}}
        ] do
      assert {:error, %Error{kind: :invalid_native_config} = error} =
               NativeConfig.from_json(type, json, existing)

      refute inspect(error) =~ "private"
    end
  end

  test "normalization is explicit and does not alter a lossless native model" do
    data = %{"config" => %{"user.native" => "true"}, "unknown" => nil}
    assert {:ok, model} = Model.decode("Profile", data)

    assert {:ok, %{"user.native" => "true"}} =
             NativeConfig.from_json("ConfigMap", Jason.encode!(model.data["config"]))

    assert Model.encode(model) == data
  end

  defp oracle(type, data, existing \\ nil) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{type: type, body: data, existing: existing}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} when byte_size(data) + byte_size(bytes) <= 1_048_576 ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)

      {^port, {:exit_status, status}} ->
        flunk("native config oracle failed #{status}: #{data}")
    after
      5000 ->
        Port.close(port)
        flunk("native config oracle deadline")
    end
  end
end
