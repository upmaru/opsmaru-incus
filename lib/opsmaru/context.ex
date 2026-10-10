defmodule Opsmaru.Context do
  @moduledoc """
  Trusted host binding for a direct library call. This is not authentication.

  The host verifies `identity`, authorizes the operation and supplies a fast,
  local `ready?` callback. Every call checks readiness before opening a backend.
  `owner` must match the connection owner. `private_state` and `capabilities`
  are host-owned references; the library neither creates nor invokes them.
  A context must never be constructed from untrusted agent request parameters.
  """
  @enforce_keys [:owner, :identity, :ready?]
  defstruct [:owner, :identity, :ready?, :private_state, capabilities: %{}]

  @type t :: %__MODULE__{
          owner: term(),
          identity: term(),
          ready?: (-> boolean()),
          private_state: String.t() | nil,
          capabilities: map()
        }

  def new!(opts) do
    context = struct!(__MODULE__, opts)

    unless context.owner != nil and context.identity != nil and
             is_function(context.ready?, 0) and is_map(context.capabilities) and
             (is_nil(context.private_state) or
                (is_binary(context.private_state) and
                   Path.type(context.private_state) == :absolute)) do
      raise ArgumentError, "invalid host context"
    end

    context
  end

  @doc false
  def authorize(%__MODULE__{owner: owner} = context, %{owner: owner}) do
    if context.ready?.() == true, do: :ok, else: {:error, :host_not_ready}
  rescue
    _ -> {:error, :host_not_ready}
  catch
    _, _ -> {:error, :host_not_ready}
  end

  def authorize(_, _), do: {:error, :owner_mismatch}
end

defimpl Inspect, for: Opsmaru.Context do
  def inspect(_, _), do: "#Opsmaru.Context<host binding redacted>"
end
