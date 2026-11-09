defmodule Opsmaru.Incus.Operations.Mutation do
  @moduledoc false
  # Submit one native mutation, then wait boundedly with the native
  # GetOperationWait. A submission is never resent; a response lost after
  # possible acceptance is reported as uncertain, and a local wait failure as
  # running, never as cancellation.
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.Operations.Result

  def submit(client, method, args, body, input, env) do
    opts = if is_nil(body), do: [], else: [body: body]

    case Incus.call(client, method, args, opts) do
      {:ok, response} ->
        wait(client, response.operation, Result.native(response), input, env)

      {:error, %Error{kind: :uncertain} = error} ->
        {:ok, uncertain(error)}

      {:error, error} ->
        {:error, error}
    end
  end

  def uncertain(%Error{} = error),
    do: %{
      "status" => "uncertain",
      "operation_id" => Result.operation_id(error.operation),
      "operation" => nil,
      "waited_seconds" => 0,
      "wait_error" => nil
    }

  def completed_sync,
    do: %{
      "status" => "completed",
      "operation_id" => nil,
      "operation" => nil,
      "waited_seconds" => 0,
      "wait_error" => nil
    }

  @doc "Wait for an operation by ID up to the requested (and connection-capped) seconds."
  def wait(client, url, snapshot, input, env) do
    id = Result.operation_id(url)

    seconds =
      effective_wait(
        client,
        Map.get(input, "wait_seconds", env.descriptor.bounds["default_wait_seconds"])
      )

    case Incus.call(client, "GetOperationWait", %{"uuid" => id, "timeout" => seconds}) do
      {:ok, response} ->
        operation = Result.native(response)

        {:ok,
         %{
           "status" => Result.operation_status(operation),
           "operation_id" => id,
           "operation" => operation,
           "waited_seconds" => seconds,
           "wait_error" => nil
         }}

      {:error, %Error{kind: kind}} ->
        {:ok,
         %{
           "status" => "running",
           "operation_id" => id,
           "operation" => snapshot,
           "waited_seconds" => seconds,
           "wait_error" => Atom.to_string(kind)
         }}
    end
  end

  # Each native request is bounded by the host connection timeout; keep one
  # second for the reply so a server-side timeout is observed, not a local one.
  def effective_wait(client, requested),
    do: min(requested, max(0, div(client.connection.timeout, 1000) - 1))
end
