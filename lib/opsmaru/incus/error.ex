defmodule Opsmaru.Incus.Error do
  @moduledoc """
  Native or local failure. `:uncertain` means a mutation may have been accepted.
  Inspect/log rendering excludes native message, response, credentials and URLs.
  Explicit fields retain backend data for caller reconciliation; never replay
  uncertain mutations automatically. Local failures do not cancel Incus work.
  """
  defstruct [:kind, :http_status, :error_code, :message, :response, :operation, :extension]
  @type t :: %__MODULE__{}
end

defimpl Inspect, for: Opsmaru.Incus.Error do
  def inspect(error, _), do: "#Opsmaru.Incus.Error<#{error.kind} details redacted>"
end
