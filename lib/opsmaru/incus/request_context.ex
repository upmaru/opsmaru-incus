defmodule Opsmaru.Incus.RequestContext do
  @moduledoc """
  Explicit local native-request lifetime, separate from host identity/readiness.

  Construction creates one cancellation cell and no process, socket or file.
  A finite absolute deadline and owner PID bound every request/channel using the
  context. Cancellation closes local resources; it never sends an Incus DELETE,
  retries a mutation or proves backend cancellation. Values are shareable with
  explicitly selected callers; clients without this context remain independent.
  """
  @enforce_keys [:owner, :deadline, :cancelled]
  defstruct [:owner, :deadline, :cancelled]

  def new!(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:timeout, :owner] == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
             is_integer(opts[:timeout]) and opts[:timeout] in 1..3_600_000 and
             is_pid(Keyword.get(opts, :owner, self())),
           do: raise(ArgumentError, "request context requires a finite timeout and local owner")

    owner = Keyword.get(opts, :owner, self())
    unless node(owner) == node(), do: raise(ArgumentError, "request context owner must be local")

    %__MODULE__{
      owner: owner,
      deadline: now() + opts[:timeout],
      cancelled: :atomics.new(1, [])
    }
  end

  def cancel(%__MODULE__{} = context) do
    validate!(context)
    kind = if now() >= context.deadline, do: 2, else: 1
    :atomics.compare_exchange(context.cancelled, 1, 0, kind)
    :ok
  end

  @doc false
  def validate!(%__MODULE__{} = context) do
    unless is_pid(context.owner) and node(context.owner) == node() and
             is_integer(context.deadline) and context.deadline <= now() + 3_600_000 and
             :atomics.info(context.cancelled).size == 1 and
             :atomics.get(context.cancelled, 1) in [0, 1, 2],
           do: raise(ArgumentError, "invalid request context")

    context
  rescue
    _ -> reraise ArgumentError.exception("invalid request context"), __STACKTRACE__
  end

  def validate!(_), do: raise(ArgumentError, "invalid request context")

  @doc "Inspect the local lifetime, without querying or cancelling Incus."
  def status(nil), do: :active

  def status(%__MODULE__{} = context) do
    case :atomics.get(context.cancelled, 1) do
      1 -> :canceled
      2 -> :deadline
      0 -> terminal_status(context)
    end
  end

  defp terminal_status(context) do
    cond do
      now() >= context.deadline ->
        :atomics.compare_exchange(context.cancelled, 1, 0, 2)
        status(context)

      not Process.alive?(context.owner) ->
        :atomics.compare_exchange(context.cancelled, 1, 0, 1)
        status(context)

      true ->
        :active
    end
  end

  @doc false
  def check(context) do
    case status(context) do
      :active -> :ok
      kind -> {:error, kind}
    end
  end

  @doc false
  def deadline(nil, deadline), do: deadline
  def deadline(context, deadline), do: min(context.deadline, deadline)

  defp now, do: System.monotonic_time(:millisecond)
end

defimpl Inspect, for: Opsmaru.Incus.RequestContext do
  def inspect(_, _), do: "#Opsmaru.Incus.RequestContext<local lifetime redacted>"
end
