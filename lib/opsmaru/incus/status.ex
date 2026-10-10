defmodule Opsmaru.Incus.Status do
  @moduledoc "Pinned native operation/instance status names; unknown numeric codes stay native."
  @names %{
    100 => "Operation created",
    101 => "Started",
    102 => "Stopped",
    103 => "Running",
    104 => "Cancelling",
    105 => "Pending",
    106 => "Starting",
    107 => "Stopping",
    108 => "Aborting",
    109 => "Freezing",
    110 => "Frozen",
    111 => "Thawed",
    112 => "Error",
    113 => "Ready",
    200 => "Success",
    400 => "Failure",
    401 => "Cancelled"
  }
  def string(code) when is_integer(code), do: Map.get(@names, code, "")
  def final?(code) when is_integer(code), do: code >= 200

  def from_string(value) when is_binary(value),
    do: Enum.find_value(@names, -1, fn {code, name} -> if value == name, do: code end)
end
