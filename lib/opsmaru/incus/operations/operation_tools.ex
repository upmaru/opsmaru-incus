defmodule Opsmaru.Incus.Operations.OperationTools do
  @moduledoc false
  # Rebind a native operation by its UUID: GetOperation, GetOperationWait and
  # DeleteOperation. A local wait failure is reported as running, never as
  # cancellation; cancel sends at most one DELETE and completion stays native.
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.Operations.{Descriptor, Mutation, Result}
  import Opsmaru.Incus.Operations.Fragments

  def descriptors do
    id = %{"project" => project(), "operation_id" => operation_id()}

    [
      %Descriptor{
        name: "incus_operation_get",
        title: "Get operation",
        description: "Read a native operation's current state by its UUID.",
        scope: "incus.read",
        input_schema: object(id, ["operation_id"]),
        output_schema: mutation_output(),
        bounds: get_bounds(),
        requires: ["GetOperation"],
        run: fn client, input, _env ->
          with {:ok, response} <-
                 Incus.call(client, "GetOperation", %{"uuid" => input["operation_id"]}),
               do: {:ok, snapshot(input["operation_id"], Result.native(response), 0)}
        end
      },
      %Descriptor{
        name: "incus_operation_wait",
        title: "Wait for operation",
        description:
          "Wait up to `wait_seconds` for a native operation to finish, using the server-side wait, and return its state.",
        scope: "incus.read",
        input_schema: object(Map.put(id, "wait_seconds", wait_seconds()), ["operation_id"]),
        output_schema: mutation_output(),
        bounds:
          Map.merge(
            get_bounds(),
            Map.take(mutation_bounds(), ["default_wait_seconds", "max_wait_seconds"])
          ),
        requires: ["GetOperationWait"],
        run: fn client, input, env ->
          uuid = input["operation_id"]

          seconds =
            Mutation.effective_wait(
              client,
              Map.get(input, "wait_seconds", env.descriptor.bounds["default_wait_seconds"])
            )

          case Incus.call(client, "GetOperationWait", %{"uuid" => uuid, "timeout" => seconds}) do
            {:ok, response} ->
              {:ok, snapshot(uuid, Result.native(response), seconds)}

            {:error, %Error{kind: kind}} when kind in [:deadline, :canceled] ->
              {:ok,
               Map.merge(snapshot(uuid, nil, seconds), %{
                 "status" => "running",
                 "wait_error" => Atom.to_string(kind)
               })}

            error ->
              error
          end
        end
      },
      %Descriptor{
        name: "incus_operation_cancel",
        title: "Cancel operation",
        description:
          "Request cancellation of a running native operation that allows it. Reports `unsupported` when the operation cannot be cancelled and `already_final` when it has finished; completion stays authoritative.",
        scope: "incus.write",
        input_schema: object(id, ["operation_id"]),
        output_schema:
          mutation_output(%{
            "cancellation" => %{
              "type" => "string",
              "enum" => ["requested", "unsupported", "already_final", "uncertain"]
            }
          }),
        bounds: get_bounds(),
        requires: ["GetOperation", "DeleteOperation"],
        run: &cancel/3
      }
    ]
  end

  defp cancel(client, input, _env) do
    uuid = input["operation_id"]

    with {:ok, response} <- Incus.call(client, "GetOperation", %{"uuid" => uuid}) do
      operation = Result.native(response)
      current = snapshot(uuid, operation, 0)

      cond do
        current["status"] != "running" ->
          {:ok, Map.put(current, "cancellation", "already_final")}

        operation["may_cancel"] != true ->
          {:ok, Map.put(current, "cancellation", "unsupported")}

        true ->
          case Incus.call(client, "DeleteOperation", %{"uuid" => uuid}) do
            {:ok, _} ->
              {:ok, Map.put(current, "cancellation", "requested")}

            {:error, %Error{kind: :uncertain}} ->
              {:ok, Map.put(current, "cancellation", "uncertain")}

            error ->
              error
          end
      end
    end
  end

  defp snapshot(uuid, operation, seconds),
    do: %{
      "status" => Result.operation_status(operation),
      "operation_id" => uuid,
      "operation" => operation,
      "waited_seconds" => seconds,
      "wait_error" => nil
    }
end
