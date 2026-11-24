defmodule Opsmaru.Incus.Gateway.Exchange do
  @moduledoc false
  # One gateway exchange: a `:start` event in the adapter process and exactly
  # one `:stop` event from an unlinked observer that monitors the process
  # owning the exchange.
  #
  # The observer exists before `:start` handlers run, so an owner killed
  # inside one still gets its `:stop`. It emits `:stop` on the first
  # `finish/2` or on the owner's `:DOWN`, whichever arrives first, then exits;
  # an owner that dies before `:start` was emitted gets no `:stop`. Owners may be killed rather
  # than asked to stop (lease interruption, deadlines, caller loss), so code
  # after a relay call is never relied on to report the end.
  #
  # Facts recorded from several processes (byte counts, status, interruption
  # reason, sent outcome, admission kind) live in one `:atomics` array that the
  # observer reads when it emits. The parsed request is sent once by the owner.
  #
  # Without `:telemetry`, or with no handler attached to the exchange events,
  # `start/1` returns an inert handle: no process or array exists and every
  # other function is a no-op. Handlers for `:stop` run in the observer, never
  # in a process that holds a backend socket.

  alias Opsmaru.Incus.Gateway.{Failure, Policy, Request}
  alias Opsmaru.Incus.Telemetry

  @prefix [:opsmaru_incus, :gateway, :exchange]
  @start [:opsmaru_incus, :gateway, :exchange, :start]
  @stop [:opsmaru_incus, :gateway, :exchange, :stop]

  @request_bytes 1
  @response_bytes 2
  @status 3
  @reason 4
  @sent 5
  @admitted 6
  @started 7

  @methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS)

  @reasons Failure.reasons()
  @outcomes [:not_sent, :uncertain, :sent]
  @admissions [:caller, :anonymous, :operation_peer, :image_peer]

  defstruct [:observer, :facts]

  @type t :: %__MODULE__{observer: pid() | nil, facts: :atomics.atomics_ref() | nil}

  @doc false
  def inert, do: %__MODULE__{}

  @doc false
  def active?(%__MODULE__{observer: observer}), do: is_pid(observer)

  @doc """
  Begin an exchange for the calling process. `fields` holds `:host` (the
  gateway's host module or `nil`), `:protocol`, `:method` and `:peer`
  (`%{address: _, port: _, certificate: der | nil}`).
  """
  def start(fields) do
    if Telemetry.list_handlers(@prefix) == [] do
      inert()
    else
      begin(fields)
    end
  end

  defp begin(fields) do
    peer = Map.get(fields, :peer) || %{}
    method = Map.get(fields, :method)

    metadata = %{
      telemetry_span_context: make_ref(),
      host: Map.get(fields, :host),
      protocol: Map.get(fields, :protocol),
      method: if(method in @methods, do: method),
      peer_address: Map.get(peer, :address),
      peer_port: Map.get(peer, :port),
      peer_fingerprint: fingerprint(Map.get(peer, :certificate))
    }

    started = System.monotonic_time()
    facts = :atomics.new(7, signed: false)
    owner = self()
    observer = spawn(fn -> observe(owner, facts, metadata, started) end)
    :atomics.put(facts, @started, 1)

    Telemetry.execute(
      @start,
      %{system_time: System.system_time(), monotonic_time: started},
      metadata
    )

    %__MODULE__{observer: observer, facts: facts}
  end

  defp fingerprint(der) when is_binary(der),
    do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  defp fingerprint(_), do: nil

  @doc """
  Record the original path once the route check accepted it, before the
  query is parsed, so a refused selection still reports its path.
  """
  def path(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def path(%__MODULE__{observer: observer} = exchange, path) when is_binary(path) do
    if Policy.route(path) == :ok, do: send(observer, {:request, %{path: path}})
    exchange
  end

  @doc "Record the parsed request. Only bounded, canonical fields are kept."
  def request(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def request(%__MODULE__{observer: observer} = exchange, %Request{} = request) do
    send(
      observer,
      {:request,
       %{
         path: request.path,
         project: request.project,
         target: request.target,
         all_projects: request.all_projects == true,
         operation: request.operation
       }}
    )

    exchange
  end

  @doc "Record how the request was admitted."
  def admitted(%__MODULE__{facts: nil} = exchange, _), do: exchange

  def admitted(%__MODULE__{facts: facts} = exchange, kind) when kind in @admissions do
    :atomics.put(facts, @admitted, index(@admissions, kind))
    exchange
  end

  @doc "Record the status of the response head sent to the caller."
  def status(%__MODULE__{facts: nil} = exchange, _), do: exchange

  def status(%__MODULE__{facts: facts} = exchange, status)
      when is_integer(status) and status in 100..999 do
    :atomics.put(facts, @status, status)
    exchange
  end

  def status(exchange, _), do: exchange

  @doc "Count body bytes read from the caller."
  def request_bytes(exchange, bytes), do: add(exchange, @request_bytes, bytes)

  @doc "Count body bytes written to the caller."
  def response_bytes(exchange, bytes), do: add(exchange, @response_bytes, bytes)

  defp add(%__MODULE__{facts: nil} = exchange, _, _), do: exchange

  defp add(%__MODULE__{facts: facts} = exchange, slot, bytes)
       when is_integer(bytes) and bytes > 0 do
    :atomics.add(facts, slot, bytes)
    exchange
  end

  defp add(exchange, _, _), do: exchange

  @doc """
  Record what the backend may have seen if the exchange ends without a
  `Failure`: `:sent` or `:uncertain` once request bytes may have reached it.
  """
  def sent(%__MODULE__{facts: nil} = exchange, _), do: exchange

  def sent(%__MODULE__{facts: facts} = exchange, outcome) when outcome in @outcomes do
    :atomics.put(facts, @sent, index(@outcomes, outcome))
    exchange
  end

  @doc """
  Record why the exchange is being interrupted, before the kill or stop that
  follows. The first recorded reason wins.
  """
  def interrupt(%__MODULE__{facts: nil} = exchange, _), do: exchange

  def interrupt(%__MODULE__{facts: facts} = exchange, reason) when reason in @reasons do
    :atomics.compare_exchange(facts, @reason, 0, index(@reasons, reason))
    exchange
  end

  @doc """
  End the exchange. `:ended` reports `outcome: :ok`, or the recorded
  interruption if there is one; a `Failure` reports its outcome and reason.
  Only the first finish (or the owner's exit) is reported.
  """
  def finish(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def finish(%__MODULE__{observer: observer} = exchange, declaration)
      when declaration == :ended or is_struct(declaration, Failure) do
    send(observer, {:finish, declaration})
    exchange
  end

  @doc """
  Move ownership to `owner`. Must be called by the current owner, so the
  transfer is observed before that owner's own exit.
  """
  def transfer(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def transfer(%__MODULE__{observer: observer} = exchange, owner) when is_pid(owner) do
    send(observer, {:transfer, owner})
    exchange
  end

  defp observe(owner, facts, metadata, started) do
    monitor = Process.monitor(owner)
    loop(owner, monitor, facts, metadata, started)
  end

  defp loop(owner, monitor, facts, metadata, started) do
    receive do
      {:request, request} ->
        loop(owner, monitor, facts, Map.merge(metadata, request), started)

      {:transfer, next} ->
        Process.demonitor(monitor, [:flush])
        loop(next, Process.monitor(next), facts, metadata, started)

      {:finish, declaration} ->
        emit(facts, drain(metadata), started, declaration)

      {:DOWN, ^monitor, :process, ^owner, _} ->
        emit(facts, drain(metadata), started, :down)
    end
  end

  # A request fact sent just before the end is still reported.
  defp drain(metadata) do
    receive do
      {:request, request} -> drain(Map.merge(metadata, request))
    after
      0 -> metadata
    end
  end

  defp emit(facts, metadata, started, declaration) do
    if :atomics.get(facts, @started) == 1,
      do: stop(facts, metadata, started, declaration),
      else: :ok
  end

  defp stop(facts, metadata, started, declaration) do
    recorded = value(@reasons, :atomics.get(facts, @reason))
    sent = value(@outcomes, :atomics.get(facts, @sent)) || :not_sent
    status = nonzero(:atomics.get(facts, @status))

    {outcome, reason, status} =
      case declaration do
        %Failure{} = failure -> {failure.outcome, failure.reason, status || failure.status}
        :ended when is_nil(recorded) -> {:ok, nil, status}
        :ended -> {sent, recorded, status}
        :down -> {sent, recorded || :killed, status}
      end

    metadata =
      Map.merge(
        %{path: nil, project: nil, target: nil, all_projects: false, operation: nil},
        metadata
      )
      |> Map.merge(%{
        admitted_as: value(@admissions, :atomics.get(facts, @admitted)),
        status: status,
        outcome: outcome,
        reason: reason
      })

    measurements = %{
      duration: System.monotonic_time() - started,
      request_bytes: :atomics.get(facts, @request_bytes),
      response_bytes: :atomics.get(facts, @response_bytes)
    }

    Telemetry.execute(@stop, measurements, metadata)
  end

  defp index(values, value), do: Enum.find_index(values, &(&1 == value)) + 1
  defp value(_, 0), do: nil
  defp value(values, index), do: Enum.at(values, index - 1)
  defp nonzero(0), do: nil
  defp nonzero(value), do: value
end
