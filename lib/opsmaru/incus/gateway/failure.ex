defmodule Opsmaru.Incus.Gateway.Failure do
  @moduledoc """
  A gateway-generated failure, encoded in the native Incus error shape.

  `outcome` states what the backend may have seen:

    * `:not_sent` - no request bytes reached the backend.
    * `:uncertain` - request bytes may have reached the backend; a mutation may
      have been accepted. The gateway never retries it.
    * `:sent` - a read-only request was sent and its response failed.

  `reason` is the closed classification reported by gateway exchange
  telemetry (see `docs/gateway.md`). It is set where each failure is built,
  never derived from the message, and never encoded.

  `operation` carries a known native operation URL when one was observed.
  Messages are fixed strings; they never include addresses, credentials or
  host callback results.
  """

  @reasons [
    :invalid_request,
    :not_configured,
    :capacity,
    :not_ready,
    :unauthorized,
    :unsupported,
    :revoked,
    :admission,
    :idle,
    :lifetime,
    :limit,
    :backend,
    :caller_closed,
    :killed
  ]

  defstruct [:status, :message, :outcome, :reason, :operation]

  @type t :: %__MODULE__{}

  @doc false
  def reasons, do: @reasons

  @doc """
  Build a failure. `opts` must carry a `:reason` from the closed set and may
  carry the native `:operation` URL.
  """
  def new(status, message, outcome, opts) when is_list(opts) do
    reason = Keyword.fetch!(opts, :reason)

    unless reason in @reasons,
      do: raise(ArgumentError, "unknown gateway failure reason: #{inspect(reason)}")

    %__MODULE__{
      status: status,
      message: message,
      outcome: outcome,
      reason: reason,
      operation: Keyword.get(opts, :operation)
    }
  end

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
