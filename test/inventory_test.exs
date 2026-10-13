defmodule Opsmaru.Incus.InventoryTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Incus.Inventory

  @inventory Path.expand("../priv/incus/inventory.json", __DIR__)

  test "pinned inventory records complete provenance and evidence slots" do
    inventory = Jason.decode!(File.read!(@inventory))
    reference = Jason.decode!(File.read!(Path.join(Path.dirname(@inventory), "reference.json")))
    assert inventory["reference"] == reference
    assert length(inventory["entries"]) == 1280
    assert length(inventory["sources"]) == 86
    assert Inventory.diff(inventory, inventory) == %{added: [], removed: [], changed: []}

    for source <- inventory["sources"] do
      assert source["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    end

    for entry <- inventory["entries"] do
      assert entry["line"] > 0
      assert is_binary(entry["signature"])
      assert Map.has_key?(entry, "elixir")
      assert is_list(entry["evidence"])
    end
  end

  test "added, removed and changed declarations cannot disappear into a count" do
    inventory = Jason.decode!(File.read!(@inventory))
    [removed, changed | rest] = inventory["entries"]
    added = %{changed | "id" => "client/function/NewPublicOperation"}
    altered = %{changed | "signature" => "func NewShape() error"}
    next = %{inventory | "entries" => [added, altered | rest]}

    assert Inventory.diff(inventory, next) == %{
             added: [added["id"]],
             removed: [removed["id"]],
             changed: [changed["id"]]
           }
  end

  test "duplicate IDs fail visibly" do
    entry = %{"id" => "same"}

    assert_raise ArgumentError, fn ->
      Inventory.diff(%{"entries" => [entry, entry]}, %{"entries" => []})
    end
  end

  test "changed source hashes invalidate every affected declaration" do
    inventory = Jason.decode!(File.read!(@inventory))
    [source | rest] = inventory["sources"]

    changed = %{
      inventory
      | "sources" => [Map.put(source, "sha256", String.duplicate("0", 64)) | rest]
    }

    affected =
      for entry <- inventory["entries"], entry["source"] == source["path"], do: entry["id"]

    assert Inventory.diff(inventory, changed).changed == Enum.sort(affected)
  end

  test "coverage accounts for every declaration without relabeling a partial slice as complete" do
    inventory = Jason.decode!(File.read!(@inventory))
    coverage = Jason.decode!(File.read!("priv/incus/coverage.json"))
    assert coverage["reference_revision"] == inventory["reference"]["revision"]
    assert coverage["complete_port"] == false
    assert Enum.map(coverage["entries"], & &1["id"]) == Enum.map(inventory["entries"], & &1["id"])
    assert Enum.any?(coverage["entries"], &(&1["status"] == "missing"))

    external_protocols =
      Enum.filter(
        coverage["entries"],
        &String.starts_with?(&1["id"], [
          "client/method/ProtocolOCI.",
          "client/method/ProtocolSimpleStreams."
        ])
      )

    assert length(external_protocols) == 40

    oci =
      Enum.filter(
        external_protocols,
        &String.starts_with?(&1["id"], "client/method/ProtocolOCI.")
      )

    assert Enum.count(oci, &(&1["status"] == "partial")) == 20
    refute Enum.any?(oci, &(&1["status"] == "missing"))

    assert Enum.all?(oci, fn entry ->
             expected =
               if String.ends_with?(entry["id"], [
                    ".GetConnectionInfo",
                    ".GetHTTPClient",
                    ".DoHTTP"
                  ]),
                  do: "test/oci_origin_reference_test.exs",
                  else: "test/oci_test.exs"

             entry["evidence"] == [expected]
           end)

    simplestreams =
      Enum.filter(
        external_protocols,
        &String.starts_with?(&1["id"], "client/method/ProtocolSimpleStreams.")
      )

    assert Enum.count(simplestreams, &(&1["status"] == "partial")) == 20
    refute Enum.any?(simplestreams, &(&1["status"] == "missing"))

    assert Enum.all?(simplestreams, fn entry ->
             entry["status"] == "missing" or
               entry["evidence"] == ["test/simple_streams_test.exs"]
           end)

    for entry <- coverage["entries"] do
      assert entry["status"] in ["partial", "missing"]

      if entry["status"] == "missing",
        do: assert(entry["elixir"] == nil and entry["evidence"] == [])

      for evidence <- entry["evidence"], do: assert(File.regular?(evidence))
    end
  end
end
