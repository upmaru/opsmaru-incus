defmodule Opsmaru.Incus.Operations.Fragments do
  @moduledoc false
  # Schema fragments and bounds shared by the descriptors. Changing one changes
  # public contract; the catalogue snapshot test pins the result.

  @no_control "^[^\\x00-\\x1f\\x7f]+$"
  @segment "^[^\\x00-\\x1f\\x7f/]+$"

  def list_bounds,
    do: %{
      "max_input_bytes" => 16_384,
      "max_output_bytes" => 262_144,
      "default_items" => 100,
      "max_items" => 500
    }

  def get_bounds, do: %{"max_input_bytes" => 16_384, "max_output_bytes" => 262_144}

  def mutation_bounds,
    do: %{
      "max_input_bytes" => 65_536,
      "max_output_bytes" => 262_144,
      "default_wait_seconds" => 10,
      "max_wait_seconds" => 60
    }

  def project,
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 1024,
      "pattern" => @segment,
      "description" => "Native Incus project. The host decides which projects the caller may use."
    }

  def name(description),
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 255,
      "pattern" => @segment,
      "description" => description
    }

  def text(max, description),
    do: %{"type" => "string", "maxLength" => max, "description" => description}

  def line(max, description),
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => max,
      "pattern" => @no_control,
      "description" => description
    }

  def fingerprint(description),
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 64,
      "pattern" => "^[0-9a-f]+$",
      "description" => description
    }

  def operation_id,
    do: %{
      "type" => "string",
      "pattern" => "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
      "description" =>
        "Native Incus operation UUID, as returned by a mutation or the operation list."
    }

  def limit,
    do: %{
      "type" => "integer",
      "minimum" => 1,
      "maximum" => 500,
      "default" => 100,
      "description" =>
        "Maximum items to return (default 100); the result reports the native total."
    }

  def wait_seconds,
    do: %{
      "type" => "integer",
      "minimum" => 0,
      "maximum" => 60,
      "default" => 10,
      "description" =>
        "Seconds to wait for completion (default 10). Capped by the host connection timeout; the result reports the effective wait."
    }

  def confirm(description),
    do: %{"type" => "string", "maxLength" => 1024, "description" => description}

  def object(properties, required \\ []) do
    schema = %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  def native_object(description), do: %{"type" => "object", "description" => description}

  def nullable_object(description),
    do: %{"type" => ["object", "null"], "description" => description}

  def list_output(description),
    do:
      object(
        %{
          "items" => %{"type" => "array", "items" => native_object(description)},
          "count" => %{
            "type" => "integer",
            "description" => "Native item total before truncation."
          },
          "truncated" => %{"type" => "boolean"}
        },
        ["items", "count", "truncated"]
      )

  def get_output(description), do: object(%{"item" => native_object(description)}, ["item"])

  @doc "Result of a mutation or operation tool, plus descriptor-specific properties."
  def mutation_output(extra \\ %{}) do
    object(
      Map.merge(
        %{
          "status" => %{
            "type" => "string",
            "enum" => ["completed", "failed", "running", "uncertain"],
            "description" =>
              "completed or failed when the outcome was observed; running when it was not observed within the wait; uncertain when the request may have been accepted without a decoded response."
          },
          "operation_id" => %{"type" => ["string", "null"]},
          "operation" => nullable_object("Latest native Operation snapshot, if known."),
          "waited_seconds" => %{"type" => "integer"},
          "wait_error" => %{"type" => ["string", "null"]}
        },
        extra
      ),
      ["status", "operation_id", "operation", "waited_seconds"]
    )
  end
end
