defmodule Opsmaru.Incus.Gateway.Failure do
  @moduledoc """
  A gateway-generated failure, encoded in the native Incus error shape.

  `outcome` states what the backend may have seen:

    * `:not_sent` - no request bytes reached the backend.
    * `:uncertain` - request bytes may have reached the backend; a mutation may
      have been accepted. The gateway never retries it.
    * `:sent` - a read-only request was sent and its response failed.

  `operation` carries a known native operation URL when one was observed.
  Messages are fixed strings; they never include addresses, credentials or
  host callback results.
  """

  defstruct [:status, :message, :outcome, :operation]

  @type t :: %__MODULE__{}

  def new(status, message, outcome, operation \\ nil),
    do: %__MODULE__{status: status, message: message, outcome: outcome, operation: operation}

  @doc "Status, headers and body for a native-shaped error response."
  def encode(%__MODULE__{} = failure) do
    gateway =
      %{"outcome" => Atom.to_string(failure.outcome)}
      |> then(&if(failure.operation, do: Map.put(&1, "operation", failure.operation), else: &1))

    body =
      Jason.encode!(%{
        "type" => "error",
        "status" => "",
        "status_code" => 0,
        "operation" => "",
        "error_code" => failure.status,
        "error" => failure.message,
        "metadata" => %{"gateway" => gateway}
      })

    {failure.status, [{"content-type", "application/json"}], body}
  end
end
