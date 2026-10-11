defmodule Opsmaru.Incus.DynamicConsole do
  @moduledoc """
  Native dynamic console: one accepted operation/control channel and repeated
  explicit data attachments. Attachments, handshake time and total lifetime are
  bounded. The creating process owns the console; its exit or explicit close
  releases local channels without cancelling the backend operation. A failed
  attachment retains the operation and never repeats the console POST.

  `attach/1` returns a native WebSocket byte channel. Hosts explicitly send/read
  binary frames through `WebSocket`, then `detach/2`; no terminal, IO device or
  platform callback is opened automatically. Control messages use native JSON. Asynchronous errors from recognized channels
  are forwarded as `{:dynamic_console, console.pid, {channel.ref, :error,
  error}}`, retaining the exact cause and accepted operation for reconciliation.
  Unknown channel references are ignored.
  """
  use GenServer
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Error, Model, Operation, WebSocket}
  defstruct [:pid, :operation]

  def open(client, instance, body, opts \\ []) do
    with :ok <- arguments(opts),
         :ok <- Context.authorize(client.context, client.connection),
         {:ok, model} <- Model.decode("InstanceConsolePost", Model.encode(body)),
         true <- is_map(model.data),
         body =
           if(model.data["type"] in [nil, ""],
             do: Map.put(model.data, "type", "console"),
             else: model.data
           ),
         {:ok, response} <-
           Incus.call(client, "ConsoleInstance", %{"instanceName" => instance}, body: body),
         {:ok, operation} <- Operation.from_response(client, response) do
      case GenServer.start(__MODULE__, {operation, self(), opts[:max_attachments] || 4},
             timeout: client.connection.timeout + 100
           ) do
        {:ok, pid} -> {:ok, %__MODULE__{pid: pid, operation: operation}}
        {:error, %Error{} = error} -> {:error, error}
        {:error, _} -> {:error, failure(operation, :stream_negotiation)}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} when is_atom(kind) -> {:error, %Error{kind: kind}}
      _ -> {:error, %Error{kind: :invalid_console_arguments}}
    end
  end

  def attach(console), do: call(console, :attach)
  def detach(console, channel), do: call(console, {:detach, channel})
  def control(console, body), do: call(console, {:control, body})

  def resize(console, width, height) when width in 1..65_535 and height in 1..65_535,
    do:
      control(console, %{
        "command" => "window-resize",
        "args" => %{"width" => Integer.to_string(width), "height" => Integer.to_string(height)}
      })

  def close(console), do: call(console, :close)

  defp call(console, request) do
    GenServer.call(console.pid, request, console.operation.client.connection.timeout + 200)
  catch
    :exit, _ -> {:error, failure(console.operation, :channel_closed)}
  end

  defp arguments(opts) do
    if Keyword.keyword?(opts) and length(opts) <= 1 and
         Enum.all?(opts, fn {key, value} ->
           key == :max_attachments and is_integer(value) and value in 1..32
         end), do: :ok, else: {:error, %Error{kind: :invalid_console_arguments}}
  end

  @impl true
  def init({operation, owner, limit}) do
    fds = get_in(Operation.data(operation), ["metadata", "fds"])

    if is_map(fds) and map_size(fds) <= 8 and
         Enum.all?(["0", "control"], fn key ->
           is_binary(fds[key]) and byte_size(fds[key]) in 1..4096
         end) do
      case Operation.websocket(operation, fds["control"]) do
        {:ok, control} ->
          lifetime = operation.client.connection.stream_timeout

          {:ok,
           %{
             operation: operation,
             owner: owner,
             owner_monitor: Process.monitor(owner),
             control: control,
             control_monitor: Process.monitor(control.pid),
             secret: fds["0"],
             attachments: %{},
             limit: limit,
             deadline: now() + lifetime,
             timer: Process.send_after(self(), :deadline, lifetime)
           }}

        {:error, error} ->
          {:stop, failure(operation, :stream_negotiation, error)}
      end
    else
      {:stop, failure(operation, :invalid_stream_metadata)}
    end
  end

  @impl true
  def handle_call(_, {caller, _}, %{owner: owner} = state) when caller != owner,
    do: {:reply, {:error, failure(state.operation, :owner_mismatch)}, state}

  def handle_call(:attach, _, state) do
    remaining = max(0, state.deadline - now())

    cond do
      remaining == 0 ->
        {:reply, {:error, failure(state.operation, :deadline)}, state}

      map_size(state.attachments) >= state.limit ->
        {:reply, {:error, failure(state.operation, :capacity)}, state}

      true ->
        original = state.operation.client.connection

        client = %{
          state.operation.client
          | connection: %{
              original
              | timeout: min(original.timeout, remaining),
                stream_timeout: remaining
            }
        }

        case Operation.websocket(%{state.operation | client: client}, state.secret) do
          {:ok, channel} ->
            monitor = Process.monitor(channel.pid)

            {:reply, {:ok, channel},
             %{state | attachments: Map.put(state.attachments, channel.pid, {channel, monitor})}}

          {:error, error} ->
            {:reply, {:error, failure(state.operation, :stream_negotiation, error)}, state}
        end
    end
  end

  def handle_call({:detach, %WebSocket{pid: pid} = supplied}, _, state) do
    case state.attachments[pid] do
      {^supplied, monitor} ->
        WebSocket.close(supplied)
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | attachments: Map.delete(state.attachments, pid)}}

      _ ->
        {:reply, {:error, failure(state.operation, :unknown_attachment)}, state}
    end
  end

  def handle_call({:detach, _}, _, state),
    do: {:reply, {:error, failure(state.operation, :unknown_attachment)}, state}

  def handle_call({:control, body}, _, state) do
    result =
      with true <- is_map(body),
           {:ok, bytes} <- Jason.encode(body),
           true <- byte_size(bytes) <= state.operation.client.connection.max_chunk_bytes do
        WebSocket.send_frame(state.control, {:text, bytes})
      else
        _ -> {:error, failure(state.operation, :invalid_console_arguments)}
      end

    {:reply, result, state}
  end

  def handle_call(:close, _, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state)
      when monitor == state.owner_monitor or monitor == state.control_monitor,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, pid, _}, state) do
    case state.attachments[pid] do
      {_, ^monitor} -> {:noreply, %{state | attachments: Map.delete(state.attachments, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(:deadline, state) do
    send(state.owner, {:dynamic_console, self(), {:error, failure(state.operation, :deadline)}})
    {:stop, :normal, state}
  end

  def handle_info({ref, :error, %Error{} = error}, state) do
    if channel_ref?(state, ref) do
      send(
        state.owner,
        {:dynamic_console, self(), {ref, :error, failure(state.operation, error.kind, error)}}
      )
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    WebSocket.close(state.control)
    Enum.each(state.attachments, fn {_, {channel, _}} -> WebSocket.close(channel) end)
  end

  @impl true
  def format_status(_), do: %{state: "native dynamic console redacted"}

  defp channel_ref?(state, ref),
    do:
      ref == state.control.ref or
        Enum.any?(state.attachments, fn {_, {channel, _}} -> channel.ref == ref end)

  defp failure(operation, kind, error \\ nil),
    do: %Error{
      kind: kind,
      operation: operation.url,
      response: %{operation: operation.response, error: error}
    }

  defp now, do: System.monotonic_time(:millisecond)
end

defimpl Inspect, for: Opsmaru.Incus.DynamicConsole do
  def inspect(_, _), do: "#Opsmaru.Incus.DynamicConsole<bound native operation redacted>"
end
