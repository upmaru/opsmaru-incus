defmodule Opsmaru.Incus.Operations.Descriptor do
  @moduledoc """
  One shared Incus operation: its public contract and how it runs.

  `name`, `input_schema`, `output_schema`, `scope`, `destructive`,
  `confirmation` and `bounds` are public contract. `requires` names the client
  evidence it depends on (see `Opsmaru.Incus.Operations.Evidence`). The
  functions are internal: `confirm` returns the resource the confirmation must
  repeat, `check` adds byte bounds the schema cannot express, `restricted`
  lists restricted input for the host, `resolve` applies host-only lookups
  before backend access and `run` executes through the public client.
  """
  @enforce_keys [:name, :title, :description, :scope, :input_schema, :output_schema, :run]
  defstruct [
    :name,
    :title,
    :description,
    :scope,
    :input_schema,
    :output_schema,
    :run,
    :confirm,
    :confirmation,
    :check,
    :restricted,
    :resolve,
    destructive: false,
    bounds: %{},
    requires: []
  ]

  @type t :: %__MODULE__{}
end
