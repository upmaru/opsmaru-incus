defmodule Opsmaru.Incus.OperationsCompositeOpenapiTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Operations.{Composite, Fragments, Schema}
  alias Opsmaru.TestSupport.ProfileChecks

  @document Composite.openapi()
  @operations Map.new(@document["paths"], fn {_, %{"post" => post}} ->
                {post["operationId"], post}
              end)

  defp schema(operation, response),
    do: operation["responses"][response]["content"]["application/json"]["schema"]

  test "the document header names the profile, source and package version" do
    assert @document["openapi"] == "3.1.1"
    assert @document["jsonSchemaDialect"] == "https://spec.openapis.org/oas/3.1/dialect/base"
    assert @document["x-tama-profile"] == "tama-operations/1"
    assert @document["x-tama-source"] == "opsmaru_incus"
    assert @document["info"]["version"] == to_string(Application.spec(:opsmaru_incus, :vsn))
    assert @document["info"]["version"] == Mix.Project.config()[:version]
  end

  test "it is pure, JSON-safe data" do
    assert Composite.openapi() == @document
    assert @document |> Jason.encode!() |> Jason.decode!() == @document
  end

  test "every exported operation appears exactly once and unavailable ones never do" do
    names = Enum.map(Composite.all(), & &1.name)
    assert length(names) == 32
    assert Enum.sort(Map.keys(@document["paths"])) == Enum.map(names, &("/operations/" <> &1))
    assert Enum.sort(Map.keys(@operations)) == names

    for %{"name" => name} <- Composite.unavailable() do
      refute Map.has_key?(@operations, name)
      refute Map.has_key?(@document["paths"], "/operations/" <> name)
    end

    refute Map.has_key?(@operations, "incus_instance_copy")
  end

  test "each operation maps field for field from its descriptor" do
    for descriptor <- Composite.all() do
      operation = @operations[descriptor.name]
      described = Composite.describe(descriptor)

      assert operation["summary"] == described["title"]
      assert operation["description"] == described["description"]
      assert operation["x-tama-scopes"] == [described["scope"]]
      assert operation["x-tama-destructive"] == described["destructive"]
      assert operation["x-tama-bounds"] == described["bounds"]
      assert operation["x-opsmaru-requires"] == described["requires"]

      assert operation["requestBody"] == %{
               "required" => true,
               "content" => %{"application/json" => %{"schema" => described["input_schema"]}}
             }

      assert Map.keys(operation["responses"]) == ["200", "default"]

      assert described["output_schema"]["oneOf"] ==
               [schema(operation, "200"), schema(operation, "default")]

      assert schema(operation, "default") == Fragments.error_schema()
    end
  end

  test "tags name the resource" do
    tags = Map.new(@operations, fn {name, operation} -> {name, operation["tags"]} end)
    assert tags["incus_instance_delete"] == ["instance"]
    assert tags["incus_instance_snapshot_restore"] == ["instance_snapshot"]
    assert tags["incus_image_alias_list"] == ["image_alias"]
    assert tags["incus_storage_volume_get"] == ["storage_volume"]
    assert tags["incus_server_get"] == ["server"]
  end

  test "destructive operations carry their scope and confirmation rule" do
    expected = %{
      "incus_instance_delete" => "the instance name",
      "incus_instance_snapshot_delete" => "`<instance>/<snapshot>`",
      "incus_instance_snapshot_restore" => "`<instance>/<snapshot>`",
      "incus_image_delete" => "the full fingerprint"
    }

    for {name, description} <- expected do
      operation = @operations[name]
      assert operation["x-tama-scopes"] == ["incus.delete"]
      assert operation["x-tama-destructive"] == true

      assert operation["x-tama-confirmation"] == %{
               "field" => "confirm",
               "description" => description
             }
    end

    confirmed = for {name, %{"x-tama-confirmation" => _}} <- @operations, do: name
    assert Enum.sort(confirmed) == Enum.sort(Map.keys(expected))

    for {name, operation} <- @operations, name not in confirmed do
      assert operation["x-tama-destructive"] == false, name
    end
  end

  test "bounds are integers taken from the descriptor" do
    assert @operations["incus_instance_list"]["x-tama-bounds"] == Fragments.list_bounds()
    assert @operations["incus_instance_delete"]["x-tama-bounds"]["max_wait_seconds"] == 60

    for {name, operation} <- @operations, {_, value} <- operation["x-tama-bounds"] do
      assert is_integer(value) and value >= 0, name
    end
  end

  test "x-opsmaru-requires keeps the client evidence requirements" do
    assert @operations["incus_instance_exec"]["x-opsmaru-requires"] ==
             ["ExecInstance", "stream:S01"]

    assert @operations["incus_server_get"]["x-opsmaru-requires"] == ["helper:connect"]
  end

  test "the 12 operations whose result carries operation identity declare it" do
    identified = for {name, %{"x-tama-identity" => identity}} <- @operations, do: {name, identity}

    assert identified |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             ~w(incus_image_delete incus_instance_create incus_instance_delete incus_instance_exec
                incus_instance_snapshot_create incus_instance_snapshot_delete
                incus_instance_snapshot_restore incus_instance_state_update incus_instance_update
                incus_operation_cancel incus_operation_get incus_operation_wait)

    for {name, identity} <- identified do
      assert identity == ["operation_id", "status"]
      properties = schema(@operations[name], "200")["properties"]
      assert Map.has_key?(properties, "operation_id") and Map.has_key?(properties, "status"), name
    end

    for {name, operation} <- @operations, not Map.has_key?(operation, "x-tama-identity") do
      properties = Map.get(schema(operation, "200"), "properties", %{})
      refute Map.has_key?(properties, "operation_id") and Map.has_key?(properties, "status"), name
    end
  end

  test "the document conforms structurally to tama-operations/1" do
    assert ProfileChecks.issues(@document) == []
  end

  test "the structural checks reject profile violations" do
    path = "/operations/incus_image_delete"
    post = @document["paths"][path]["post"]
    put = fn key, value -> put_in(@document, ["paths", path, "post", key], value) end

    broken = [
      Map.put(@document, "x-tama-profile", "tama-operations/2"),
      Map.put(@document, "x-tama-source", "Opsmaru"),
      Map.put(@document, "x-tama-unknown", true),
      Map.put(@document, "webhooks", %{}),
      put.("operationId", "incus_image_remove"),
      put.("summary", String.duplicate("s", 121)),
      put.("parameters", []),
      put.("x-tama-scopes", []),
      put.("x-tama-destructive", "yes"),
      put.("x-tama-confirmation", %{"field" => "fingerprint2", "description" => "x"}),
      put.("x-tama-confirmation", %{"field" => "wait_seconds", "description" => "x"}),
      put.("x-tama-bounds", %{"max_items" => 1.5}),
      put.("x-tama-identity", ["operation_id", "missing"]),
      put.("responses", Map.put(post["responses"], "404", post["responses"]["default"])),
      put.("requestBody", Map.put(post["requestBody"], "required", false)),
      put_in(
        @document,
        ["paths", path, "post", "requestBody", "content", "application/json", "schema"],
        %{"type" => "object", "allOf" => []}
      ),
      put_in(@document, ["paths", path, "get"], post)
    ]

    for document <- broken, do: assert(ProfileChecks.issues(document) != [])
  end

  test "input and result schemas validate real values" do
    delete = @operations["incus_image_delete"]
    input = delete["requestBody"]["content"]["application/json"]["schema"]
    fingerprint = String.duplicate("a", 64)

    assert :ok = Schema.validate(input, %{"fingerprint" => fingerprint, "confirm" => fingerprint})
    assert {:error, "/confirm", "is required"} = Schema.validate(input, %{"fingerprint" => "ab"})

    assert :ok =
             Schema.validate(schema(delete, "default"), %{
               "error" => %{"kind" => "confirmation_required", "message" => "m"}
             })
  end
end
