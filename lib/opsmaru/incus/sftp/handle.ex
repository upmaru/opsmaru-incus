defmodule Opsmaru.Incus.SFTP.Handle do
  @moduledoc "Opaque native file handle bound to one SFTP session; its bytes are privileged data."
  @enforce_keys [:session, :value]
  defstruct [:session, :value]
end

defimpl Inspect, for: Opsmaru.Incus.SFTP.Handle do
  def inspect(_, _), do: "#Opsmaru.Incus.SFTP.Handle<native bytes redacted>"
end
