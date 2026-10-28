defmodule Opsmaru.Incus.Session do
  @moduledoc "Native exec/console channels and controls, retaining accepted operation identity."
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.ExecOutput
  alias Opsmaru.Incus.ExecRun
  alias Opsmaru.Incus.Model
  alias Opsmaru.Incus.Operation
  alias Opsmaru.Incus.WebSocket
  defstruct [:operation, :owner, collectable?: false, console?: false, channels: %{}]

  def exec(client, instance, body), do: exec(client, instance, body, fn _ -> :ok end)

  @doc false
  def exec(client, instance, body, accepted) do
    body = Model.encode(body)

    with {:ok, response} <-
           Incus.call(client, "ExecInstance", %{"instanceName" => instance}, body: body),
         {:ok, operation} <- Operation.from_response(client, response),
         :ok <- accepted.(operation),
         {:ok, session} <- channels(operation) do
      collectable? =
        body["interactive"] in [nil, false] and body["record-output"] in [nil, false] and
          body["wait-for-websocket"] == true

      {:ok, %{session | collectable?: collectable?}}
    end
  end

  @doc """
  Collect creator-owned live noninteractive exec output through two binary sinks
  returning `:ok`. Send stdin with `input/2` first; collection sends its write
  barrier, closes local channels after collection starts and never cancels Incus.
  `:timeout` covers collection, callbacks and final operation wait (at most the
  connection's stream timeout); `:max_output_bytes` bounds stdout + stderr.
  Returns final `:operation`, native `:exit_status` and per-stream byte counts.
  A limit fails visibly rather than truncating. Recorded/interactive sessions
  and foreign creators reject before IO. See `docs/incus-client.md` for scope.
  """
  def collect(session, stdout, stderr, opts \\ []),
    do: ExecOutput.collect(session, stdout, stderr, opts)

  @doc """
  Submit live noninteractive exec and exchange finite binary stdin with acknowledged
  output sinks concurrently. Options are `:timeout`, `:max_input_bytes` and
  `:max_output_bytes`, capped by connection limits. One lifetime covers submission
  through completion. Local failures never cancel or replay Incus; known accepted
  identity remains usable through the original client. See `docs/incus-client.md`.
  """
  def run(client, instance, body, stdin, stdout, stderr, opts \\ []),
    do: ExecRun.run(client, instance, body, stdin, stdout, stderr, opts)

  @doc """
  Attach to an instance console as the pinned `ConsoleInstance` does: the body
  is an `InstanceConsolePost` (type defaults to `"console"`), and the control
  channel opens before channel 0. Other accepted channels are ignored. Missing
  secrets fail closed with the accepted operation and open no channel. Hosts
  drive frames, barriers and resize explicitly; `close/1` detaches.
  """
  def console(client, instance, body) do
    with {:ok, body} <- console_body(body),
         {:ok, response} <-
           Incus.call(client, "ConsoleInstance", %{"instanceName" => instance}, body: body),
         {:ok, operation} <- Operation.from_response(client, response) do
      fds = get_in(Operation.data(operation), ["metadata", "fds"])

      if is_map(fds) and map_size(fds) <= 8 and
           Enum.all?(["control", "0"], &secret?(fds[&1])) do
        open(operation, [{"control", fds["control"]}, {"0", fds["0"]}], true)
      else
        {:error, invalid_metadata(operation)}
      end
    end
  end

  # The catalogue applies the "console" type default and its extension guards.
  @doc false
  def console_body(body) do
    case Model.decode("InstanceConsolePost", Model.encode(body)) do
      {:ok, %{data: data}} when is_map(data) -> {:ok, data}
      _ -> {:error, %Error{kind: :invalid_console_arguments}}
    end
  end

  defp channels(operation) do
    fds = get_in(Operation.data(operation), ["metadata", "fds"]) || %{}

    if is_map(fds) and map_size(fds) <= 8 and
         Enum.all?(fds, fn {name, secret} ->
           name in ["0", "1", "2", "control"] and secret?(secret)
         end) do
      open(operation, fds, false)
    else
      {:error, invalid_metadata(operation)}
    end
  end

  defp secret?(secret), do: is_binary(secret) and byte_size(secret) in 1..4096

  defp invalid_metadata(operation),
    do: %Error{
      kind: :invalid_stream_metadata,
      response: operation.response,
      operation: operation.url
    }

  defp open(operation, fds, console?) do
    initial = %__MODULE__{operation: operation, owner: self(), console?: console?}

    Enum.reduce_while(fds, {:ok, initial}, fn {name, secret}, {:ok, session} ->
      case Operation.websocket(operation, secret) do
        {:ok, channel} ->
          {:cont, {:ok, %{session | channels: Map.put(session.channels, name, channel)}}}

        {:error, %Error{kind: kind}} when kind in [:deadline, :canceled] ->
          close(session)

          {:halt,
           {:error, %Error{kind: kind, response: operation.response, operation: operation.url}}}

        {:error, error} ->
          close(session)

          {:halt,
           {:error,
            %Error{
              kind: :stream_negotiation,
              response: %{operation: operation.response, error: error},
              operation: operation.url
            }}}
      end
    end)
  end

  def input(session, bytes), do: send_channel(session, "0", {:binary, bytes})
  @doc "Send the native write barrier without closing output/control channels."
  def close_input(session), do: send_channel(session, "0", {:text, ""})

  @doc "Receive one frame; the default channel is 0 for a console and 1 for exec."
  def output(session, channel \\ :default, timeout \\ 5_000) do
    channel = if channel == :default, do: if(session.console?, do: "0", else: "1"), else: channel

    case Map.fetch(session.channels, channel) do
      {:ok, stream} -> WebSocket.recv(stream, timeout)
      :error -> {:error, %Error{kind: :missing_channel}}
    end
  end

  def control(session, body) when is_map(body),
    do: send_channel(session, "control", {:text, Jason.encode!(body)})

  def resize(session, width, height) when width in 1..65_535 and height in 1..65_535,
    do:
      control(session, %{
        "command" => "window-resize",
        "args" => %{"width" => Integer.to_string(width), "height" => Integer.to_string(height)}
      })

  def signal(session, signal) when signal in 1..64,
    do: control(session, %{"command" => "signal", "signal" => signal})

  def exit_status(session) do
    with {:ok, current} <- Operation.poll(session.operation) do
      value = get_in(Operation.data(current), ["metadata", "return"])

      if Operation.completed?(current) and is_integer(value),
        do: {:ok, value},
        else:
          {:error,
           %Error{kind: :operation_pending, response: current.response, operation: current.url}}
    end
  end

  @doc """
  Close the local channels without cancelling Incus. A console's control channel
  receives the pinned `1000 "Detaching from console"` close frame.
  """
  def close(%__MODULE__{console?: true} = session) do
    {control, data} = Map.pop(session.channels, "control")
    WebSocket.close_owned(detach_frames(control) ++ Map.values(data))
  end

  def close(session) do
    WebSocket.close_owned(Map.values(session.channels))
  end

  @doc false
  def detach_frames(nil), do: []
  def detach_frames(control), do: [{control, {1000, "Detaching from console"}}]

  defp send_channel(session, name, frame) do
    case Map.fetch(session.channels, name) do
      {:ok, channel} -> WebSocket.send_frame(channel, frame)
      :error -> {:error, %Error{kind: :missing_channel}}
    end
  end
end

defimpl Inspect, for: Opsmaru.Incus.Session do
  def inspect(_, _), do: "#Opsmaru.Incus.Session<native channels redacted>"
end
