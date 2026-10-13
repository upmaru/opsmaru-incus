defmodule Opsmaru.Incus.NestedModelsReferenceTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000

  alias Opsmaru.Incus.Model

  @driver Path.expand("../.integration/nested-models-driver", __DIR__)
  @schemas Jason.decode!(File.read!(Path.expand("../priv/incus/models.json", __DIR__)))[
             "models"
           ]

  @types ~w(
    AccessEntry
    BackupTarget
    CertificateAddToken
    ClusterMemberConfigKey
    ClusterMemberJoinToken
    ClusterMemberSysInfo
    ImageAlias
    ImageMetadataTemplate
    ImageSource
    ImagesPostSource
    InstanceConsoleControl
    InstanceDebugRepairPost
    InstanceExecControl
    InstancePostTarget
    InstanceSource
    InstanceStateCPU
    InstanceStateDisk
    InstanceStateMemory
    InstanceStateNetwork
    InstanceStateNetworkAddress
    InstanceStateNetworkCounters
    InstanceStateOSInfo
    InstanceType
    NetworkLoadBalancerStateBackendHealth
    NetworkLoadBalancerStateBackendHealthPort
    NetworkStateAddress
    NetworkStateBond
    NetworkStateBridge
    NetworkStateCounters
    NetworkStateOVN
    NetworkStateVLAN
    NetworkZoneRecordEntry
    ProjectStateResource
    ResourcesCPU
    ResourcesCPUAddressSizes
    ResourcesCPUCache
    ResourcesCPUCore
    ResourcesCPUSocket
    ResourcesCPUThread
    ResourcesGPU
    ResourcesGPUCard
    ResourcesGPUCardDRM
    ResourcesGPUCardMdev
    ResourcesGPUCardNvidia
    ResourcesGPUCardSRIOV
    ResourcesLoad
    ResourcesMemory
    ResourcesMemoryNode
    ResourcesNetwork
    ResourcesNetworkCard
    ResourcesNetworkCardPort
    ResourcesNetworkCardPortInfiniband
    ResourcesNetworkCardSRIOV
    ResourcesNetworkCardVDPA
    ResourcesPCI
    ResourcesPCIDevice
    ResourcesPCIVPD
    ResourcesSerial
    ResourcesSerialDevice
    ResourcesStorage
    ResourcesStorageDisk
    ResourcesStorageDiskPartition
    ResourcesStoragePoolInodes
    ResourcesStoragePoolSpace
    ResourcesSystem
    ResourcesSystemChassis
    ResourcesSystemFirmware
    ResourcesSystemMotherboard
    ResourcesUSB
    ResourcesUSBDevice
    ResourcesUSBDeviceInterface
    ServerStorageDriverInfo
    ServerUntrusted
    StorageBucketBackup
    StorageBucketBackupPost
    StoragePoolState
    StorageVolumePostTarget
    StorageVolumeSource
    StorageVolumeStateUsage
  )

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./nestedmodels"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  for type <- @types do
    test "#{type}: fully populated value is native-accepted, canonical and schema-complete" do
      populated_case(unquote(type))
    end

    test "#{type}: empty and all-null input are accepted natively and by Model.decode" do
      empty_case(unquote(type))
    end

    test "#{type}: wrong-typed field values are rejected natively and by Model.decode" do
      negative_case(unquote(type))
    end
  end

  test "native requires RFC3339 for time.Time while Elixir accepts any binary" do
    value = populated("CertificateAddToken") |> Map.put("expires_at", "not-a-time")
    [result] = oracle("CertificateAddToken", value)

    refute result["accepted"], "native accepted non-RFC3339 time"

    assert {:ok, %Model{type: "CertificateAddToken", data: data}} =
             Model.decode("CertificateAddToken", value)

    assert data["expires_at"] == "not-a-time"
  end

  test "native silently drops unknown fields while Elixir retains them" do
    value = populated("AccessEntry") |> Map.put("extra", "kept")
    [result] = oracle("AccessEntry", value)

    assert result["accepted"], "native rejected unknown-field input"
    canonical = Jason.decode!(result["canonical"])
    refute Map.has_key?(canonical, "extra")

    assert {:ok, %Model{data: data}} = Model.decode("AccessEntry", value)
    assert data["extra"] == "kept"
  end

  defp populated_case(type) do
    value = populated(type)
    [result] = oracle(type, value)

    assert result["accepted"], "native rejected fully populated #{type}"
    assert {:ok, %Model{type: ^type, data: ^value}} = Model.decode(type, value)

    canonical = Jason.decode!(result["canonical"])
    assert {:ok, _} = Model.decode(type, canonical)

    if struct?(type) do
      compare_schema_keys(type, canonical)
    end
  end

  defp compare_schema_keys(type, canonical) do
    expected = MapSet.new(field_names(type))
    actual = MapSet.new(Map.keys(canonical))
    missing = MapSet.difference(expected, actual)
    extra = MapSet.difference(actual, expected)

    assert missing == %MapSet{},
           "schema fields Go never emits for #{type}: #{inspect(Enum.sort(missing))}"

    assert extra == %MapSet{},
           "keys Go emits that are missing from the schema for #{type}: #{inspect(Enum.sort(extra))}"
  end

  defp empty_case(type) do
    cases = empty_cases(type)

    for {value, result} <- Enum.zip(cases, oracle_all(type, cases)) do
      assert result["accepted"], "native rejected #{type} input #{inspect(value)}"
      assert {:ok, _} = Model.decode(type, value)
    end
  end

  defp negative_case(type) do
    cases = negative_cases(type)
    results = oracle_all(type, Enum.map(cases, & &1.value))

    for {c, result} <- Enum.zip(cases, results) do
      refute result["accepted"], c.label
      assert {:error, :invalid_model} = Model.decode(type, c.value)
    end
  end

  @max_depth 3

  defp schema(type), do: @schemas[type]
  defp struct?(type), do: schema(type)["kind"] == "struct"
  defp field_names(type), do: schema(type)["fields"] |> Enum.map(& &1["name"])

  # Schemas are mutually recursive (ResourcesGPUCard <-> ResourcesGPUCardSRIOV,
  # ResourcesNetworkCard <-> ResourcesNetworkCardSRIOV), so depth is bounded:
  # structs at or past the limit become null, struct slices [] and struct maps %{}.
  defp populated(type), do: populated(type, 0)

  defp populated(type, depth) do
    case schema(type) do
      %{"kind" => "struct"} ->
        if depth >= @max_depth do
          nil
        else
          Enum.reduce(schema(type)["fields"], %{}, fn field, acc ->
            Map.put(acc, field["name"], value_for(field["type"], depth + 1))
          end)
        end

      %{"underlying" => underlying} ->
        value_for(underlying, depth)
    end
  end

  defp empty_cases(type) do
    if struct?(type) do
      [%{}, Map.new(field_names(type), fn name -> {name, nil} end)]
    else
      [nil, value_for(schema(type)["underlying"], 0)]
    end
  end

  defp negative_cases(type) do
    if struct?(type) do
      value = populated(type)

      for field <- schema(type)["fields"],
          bad <- field_negatives(field["type"], value, field["name"]) do
        %{value: bad, label: "#{type}.#{field["name"]} (#{field["type"]})"}
      end
    else
      for bad <- wrong_scalar(schema(type)["underlying"]) do
        %{value: bad, label: "#{type} (#{schema(type)["underlying"]})"}
      end
    end
  end

  defp value_for("string", _depth), do: "text"
  defp value_for("bool", _depth), do: true
  defp value_for("int", _depth), do: 1
  defp value_for("int64", _depth), do: 1
  defp value_for("uint16", _depth), do: 1
  defp value_for("uint64", _depth), do: 1
  defp value_for("float64", _depth), do: 1.5
  defp value_for("time.Time", _depth), do: "2026-01-02T15:04:05Z"
  defp value_for("[]byte", _depth), do: Base.encode64("ab")
  defp value_for("[]string", _depth), do: ["a"]
  defp value_for("[]float64", _depth), do: [1.5]
  defp value_for("map[string]string", _depth), do: %{"key" => "value"}

  defp value_for("[]" <> element, depth) do
    if depth >= @max_depth, do: [], else: [value_for(element, depth)]
  end

  defp value_for("map[string]" <> element, depth) do
    if depth >= @max_depth, do: %{}, else: %{"key" => value_for(element, depth)}
  end

  defp value_for("*" <> inner, depth), do: value_for(inner, depth)
  defp value_for(type, depth), do: populated(type, depth)

  defp field_negatives("string", value, name), do: [Map.put(value, name, 42)]

  defp field_negatives("bool", value, name),
    do: [Map.put(value, name, "yes"), Map.put(value, name, 42)]

  defp field_negatives("float64", value, name), do: [Map.put(value, name, "1.5")]
  defp field_negatives("time.Time", value, name), do: [Map.put(value, name, 42)]

  defp field_negatives(type, value, name) when type in ["int", "int64", "uint16", "uint64"] do
    negatives = [
      Map.put(value, name, "7"),
      Map.put(value, name, 1.5),
      Map.put(value, name, out_of_range(type))
    ]

    if String.starts_with?(type, "uint") do
      negatives ++ [Map.put(value, name, -1)]
    else
      negatives
    end
  end

  defp field_negatives(_, value, name), do: [Map.put(value, name, "not an object")]

  defp wrong_scalar("string"), do: [42, true]
  defp wrong_scalar(_), do: ["not an object", 42]

  defp out_of_range("int"), do: 9_223_372_036_854_775_808
  defp out_of_range("int64"), do: 9_223_372_036_854_775_808
  defp out_of_range("uint16"), do: 65_536
  defp out_of_range("uint64"), do: 18_446_744_073_709_551_616

  defp oracle(type, value), do: oracle_all(type, [value])

  defp oracle_all(type, values) do
    cases = Enum.map(values, fn value -> %{"type" => type, "json" => Jason.encode!(value)} end)

    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{cases: cases}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)["results"]

      {^port, {:exit_status, status}} ->
        flunk("native model oracle failed #{status}: #{data}")
    after
      10_000 ->
        Port.close(port)
        flunk("native model oracle deadline")
    end
  end
end
