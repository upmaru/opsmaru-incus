defmodule Opsmaru.Incus.Redaction do
  @moduledoc false

  # OTP's format_status/1 must return the given map with only its known keys.
  # The state, the last message and the debug log can carry frames, secrets or
  # exec input, so a crash report or :sys.get_status shows none of them.
  def status(status, state) do
    status
    |> Map.put(:state, state)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end
end
