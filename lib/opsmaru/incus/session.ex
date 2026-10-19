defmodule Opsmaru.Incus.Session do
  @moduledoc "Native exec/console channels and controls, retaining accepted operation identity."
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.ExecOutput
  alias Opsmaru.Incus.ExecRun
  alias Opsmaru.Incus.Model
  alias Opsmaru.Incus.Operation
  alias Opsmaru.Incus.WebSocket
  defstruct [:operation, :owner, collectable?: false, channels: %{}]

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

  def console(client, instance, body) do
    body = Model.encode(body)
    body = if body["type"] in [nil, ""], do: Map.put(body, "type", "console"), else: body

    with {:ok, response} <-
           Incus.call(client, "ConsoleInstance", %{"instanceName" => instance}, body: body),
         {:ok, operation} <- Operation.from_response(client, response) do
      channels(operation)
    end
  end

  defp channels(operation) do
    fds = get_in(Operation.data(operation), ["metadata", "fds"]) || %{}

    if is_map(fds) and map_size(fds) <= 8 and
         Enum.all?(fds, fn {name, secret} ->
           name in ["0", "1", "2", "control"] and is_binary(secret) and
             byte_size(secret) in 1..4096
         end) do
      initial = %__MODULE__{operation: operation, owner: self()}

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
    else
      {:error,
       %Error{
         kind: :invalid_stream_metadata,
         response: operation.response,
         operation: operation.url
       }}
    end
  end

  def input(session, bytes), do: send_channel(session, "0", {:binary, bytes})
  @doc "Send the native write barrier without closing output/control channels."
  def close_input(session), do: send_channel(session, "0", {:text, ""})

  def output(session, channel \\ "1", timeout \\ 5_000) do
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

  def close(session) do
    WebSocket.close_owned(Map.values(session.channels))
  end

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
