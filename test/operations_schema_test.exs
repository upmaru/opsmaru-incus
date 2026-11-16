defmodule Opsmaru.Incus.OperationsSchemaTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Operations.Schema

  test "number accepts integers and floats and rejects other values" do
    schema = %{"type" => "number"}
    for value <- [0, -3, 1.5, -0.5], do: assert(:ok = Schema.validate(schema, value))

    for value <- ["1", true, nil, [], %{}] do
      assert {:error, "", "must be number"} = Schema.validate(schema, value)
    end

    assert {:error, "", "must be integer"} = Schema.validate(%{"type" => "integer"}, 1.5)
  end

  test "minimum and maximum bound floats as well as integers" do
    schema = %{"type" => "number", "minimum" => 0, "maximum" => 10}

    for value <- [0, 0.0, 0.5, 10, 10.0], do: assert(:ok = Schema.validate(schema, value))

    for value <- [-1, -0.5, -1.0e-9] do
      assert {:error, "", "is below its minimum"} = Schema.validate(schema, value)
    end

    for value <- [11, 10.5, 10.000001] do
      assert {:error, "", "is above its maximum"} = Schema.validate(schema, value)
    end

    fractional = %{"type" => "number", "minimum" => 0.5, "maximum" => 1.5}
    assert :ok = Schema.validate(fractional, 1)
    assert {:error, "", "is below its minimum"} = Schema.validate(fractional, 0)
    assert {:error, "", "is above its maximum"} = Schema.validate(fractional, 2)

    nested = %{"type" => "object", "properties" => %{"ratio" => schema}}

    assert {:error, "/ratio", "is below its minimum"} =
             Schema.validate(nested, %{"ratio" => -0.5})
  end

  test "bounds do not apply to values that are not numbers" do
    assert :ok = Schema.validate(%{"minimum" => 5}, "text")
    assert :ok = Schema.validate(%{"minimum" => 5}, nil)
  end

  test "$ref resolves into the given components and fails when it does not" do
    components = %{
      "Size" => %{"type" => "number", "minimum" => 0},
      "Node" => %{
        "type" => "object",
        "properties" => %{
          "size" => %{"$ref" => "#/components/schemas/Size"},
          "next" => %{"oneOf" => [%{"$ref" => "#/components/schemas/Node"}, %{"type" => "null"}]}
        },
        "additionalProperties" => false
      }
    }

    schema = %{"$ref" => "#/components/schemas/Node"}
    value = %{"size" => 1.5, "next" => %{"size" => 2, "next" => nil}}
    assert :ok = Schema.validate(schema, value, components)

    assert {:error, "/size", "is below its minimum"} =
             Schema.validate(schema, %{value | "size" => -0.1}, components)

    assert {:error, "/next", "must match exactly one schema"} =
             Schema.validate(schema, put_in(value, ["next", "size"], -0.1), components)

    assert {:error, "/extra", "is not allowed"} =
             Schema.validate(schema, Map.put(value, "extra", 1), components)

    assert {:error, "", "refers to an unknown schema"} = Schema.validate(schema, value)

    for ref <- ["#/components/schemas/Missing", "#/definitions/Node", "https://example.com/x"] do
      assert {:error, "", "refers to an unknown schema"} =
               Schema.validate(%{"$ref" => ref}, value, components)
    end
  end
end
