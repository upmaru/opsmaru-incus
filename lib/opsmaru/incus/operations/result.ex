defmodule Opsmaru.Incus.Operations.Result do
  @moduledoc false
  # JSON-safe result and error values shared by the descriptors.
  alias Opsmaru.Incus.{Error, Model, Operation, Response}

  @message_bytes 1024

  def error(kind, message, extra \\ %{}),
    do: {:error, Map.merge(%{"kind" => kind, "message" => message}, extra)}

  @doc "A client error as a tool error, keeping native status, code, message and operation identity."
  def client_error(%Error{kind: :native} = error) do
    error("native", bounded(error.message || "native error"), %{
      "http_status" => error.http_status,
      "error_code" => error.error_code,
      "operation_id" => operation_id(error.operation)
    })
    |> compact()
  end

  def client_error(%Error{kind: kind} = error) do
    error(Atom.to_string(kind), describe(kind), %{"operation_id" => operation_id(error.operation)})
    |> compact()
  end

  def client_error(other), do: error("client", "client call failed: #{inspect(other)}")

  defp compact({:error, map}), do: {:error, Map.reject(map, fn {_, value} -> is_nil(value) end)}

  defp describe(:uncertain), do: "the request may have been accepted; it was not resent"
  defp describe(:deadline), do: "the local deadline expired; Incus work was not cancelled"
  defp describe(:host_not_ready), do: "the host backend is not ready"
  defp describe(:unsupported_extension), do: "the server lacks a required API extension"
  defp describe(kind), do: "client call failed (#{kind})"

  def bounded(message) when is_binary(message) do
    if byte_size(message) <= @message_bytes,
      do: message,
      else: String.byte_slice(message, 0, @message_bytes - 3) <> "…"
  end

  def bounded(_), do: ""

  @doc "Native operation ID from an operation URL, or nil."
  def operation_id("/1.0/operations/" <> id) when id != "", do: id
  def operation_id(_), do: nil

  @doc "Native data of a response, model or operation."
  def native(%Response{metadata: metadata}), do: native(metadata)
  def native(%Model{data: data}), do: data
  def native(%Operation{} = operation), do: Operation.data(operation)
  def native(data), do: data

  @doc "completed / failed / running from a native Operation snapshot."
  def operation_status(%{"status_code" => 200}), do: "completed"

  def operation_status(%{"status_code" => code}) when is_integer(code) and code >= 400,
    do: "failed"

  def operation_status(_), do: "running"

  @doc "Bound a native list to `limit` items and `max_bytes` of JSON, keeping native order."
  def list(items, limit, max_bytes) do
    kept = Enum.take(items, limit)

    result = fn kept ->
      %{"items" => kept, "count" => length(items), "truncated" => length(kept) < length(items)}
    end

    fit(kept, items, result, max_bytes)
  end

  # Items are dropped from the end; a list whose first item alone exceeds the
  # bound fails rather than returning an empty page.
  defp fit(kept, items, result, max_bytes) do
    value = result.(kept)

    cond do
      kept == [] and items != [] -> error("output_limit", "one item exceeds the output bound")
      json_bytes(value) <= max_bytes -> {:ok, value}
      true -> fit(Enum.drop(kept, -max(1, div(length(kept), 8))), items, result, max_bytes)
    end
  end

  @doc "Fail visibly when one value exceeds the output bound."
  def within(value, max_bytes) do
    if json_bytes(value) <= max_bytes,
      do: {:ok, value},
      else: error("output_limit", "the result exceeds the output bound")
  end

  def json_bytes(value), do: value |> Jason.encode!() |> byte_size()
end
