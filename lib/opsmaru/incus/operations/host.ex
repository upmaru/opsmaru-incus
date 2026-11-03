defmodule Opsmaru.Incus.Operations.Host do
  @moduledoc """
  Host binding for shared Incus operations. The host owns every trust decision.

  For an authenticated `caller` (a host-owned term, for MCP the
  `TamaMCP.Context`), the host returns the trusted backend and authorizes each
  operation with its validated input. Tool input never selects a socket, URL,
  credential, owner or host path; the operation selects a native `project`
  from input only after `authorize/3` returns `:ok`.

  A callback that is missing, raises, exits or returns anything else denies
  the call before any backend request. Calls run in the caller's process.
  """
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context}

  @type caller :: term()
  @type operation :: String.t()

  @doc """
  The backend for this caller and operation: a discovered client, or a
  connection and context the operation discovers with `Opsmaru.Incus.connect/2`
  after authorization. The connection's `timeout` bounds every native request,
  including bounded waits.
  """
  @callback binding(caller(), operation()) ::
              {:ok, Incus.t()} | {:ok, Connection.t(), Context.t()} | {:error, term()}

  @doc "Authorize the operation and its validated, normalized input (including `project`)."
  @callback authorize(caller(), operation(), input :: map()) :: :ok | {:error, term()}

  @doc """
  Resolve a host-approved image remote named in create input to its native
  source `server` and `protocol`. Without this callback only local images are used.
  """
  @callback image_remote(caller(), name :: String.t()) ::
              {:ok, %{required(String.t()) => String.t()}} | {:error, term()}

  @doc """
  Allow restricted create/update input: each item is `{:config, key}` or
  `{:device, name}`. Without this callback restricted input is denied.
  """
  @callback allow_restricted?(caller(), operation(), items :: [{:config | :device, String.t()}]) ::
              boolean()

  @optional_callbacks image_remote: 2, allow_restricted?: 3
end
