defmodule Opsmaru.Incus.Migration do
  @moduledoc """
  Native pull/push/relay negotiation between two explicit host-bound clients.

  `negotiate/5` takes source and target native request tuples
  `{method_name, arguments, body}`. The host supplies the target configuration
  and approves exactly one HTTPS origin for pull/push. Advertised backend
  addresses are never followed. It returns accepted operation handles, not
  completed workloads. Failures retain every accepted handle and never retry,
  cancel or delete backend data. `relay/2` explicitly forwards bounded native
  WebSocket channels; reset/reconnection requires caller reconciliation.
  """
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Error, Model, Operation, WebSocket}
  defstruct [:source, :target, :mode]

  def negotiate(source, target, source_request, target_request, opts \\ []) do
    mode = opts[:mode] || :pull

    with :ok <- Context.authorize(source.context, source.connection),
         :ok <- Context.authorize(target.context, target.connection),
         :ok <- requests(source_request, target_request),
         :ok <- origin(mode, opts[:approved_origin], if(mode == :push, do: target, else: source)) do
      initial = %__MODULE__{mode: mode}

      if mode == :push do
        case issue(target, put_source(target_request, %{"type" => "migration", "mode" => "push"})) do
          {:ok, target_op} ->
            state = %{initial | target: target_op}

            with {:ok, secrets} <- secrets(target_op),
                 descriptor = descriptor(target, target_op, secrets, opts[:approved_origin]),
                 {:ok, source_op} <- issue(source, put_body(source_request, "target", descriptor)) do
              {:ok, %{state | source: source_op}}
            else
              {:error, error} -> failure(state, error, nil)
            end

          {:error, error} ->
            failure(initial, error, nil)
        end
      else
        # Track the accepted source before any target request can fail.
        case issue(source, source_request) do
          {:ok, source_op} ->
            state = %{initial | source: source_op}
            negotiate_target(state, source, target, target_request, opts)

          {:error, error} ->
            failure(initial, error, nil)
        end
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp negotiate_target(state, source, target, request, opts) do
    with {:ok, secrets} <- secrets(state.source) do
      fields =
        if state.mode == :relay,
          do: %{"type" => "migration", "mode" => "push"},
          else:
            Map.merge(descriptor(source, state.source, secrets, opts[:approved_origin]), %{
              "type" => "migration",
              "mode" => "pull"
            })

      case issue(target, put_source(request, fields)) do
        {:ok, target_op} -> {:ok, %{state | target: target_op}}
        {:error, error} -> failure(state, error, nil)
      end
    else
      {:error, error} -> failure(state, error, nil)
    end
  end

  defp requests({source, args, body}, {target, target_args, target_body}) do
    if source in ["MigrateInstance", "MigrateInstanceSnapshot", "MigrateStoragePoolVolume"] and
         ((source == "MigrateStoragePoolVolume" and
             target == "CreateStoragePoolVolumeFromMigration") or
            (source != "MigrateStoragePoolVolume" and target == "CreateInstance")) and
         is_map(args) and is_map(target_args) and is_map(Model.encode(body)) and
         Model.encode(body)["migration"] == true and is_map(Model.encode(target_body)),
       do: :ok,
       else: {:error, :invalid_migration_request}
  end

  defp requests(_, _), do: {:error, :invalid_migration_request}

  defp origin(:relay, nil, _), do: :ok

  defp origin(mode, approved, client) when mode in [:pull, :push] do
    if client.connection.transport == :https and
         approved == URI.to_string(client.connection.address),
       do: :ok,
       else: {:error, :unapproved_migration_origin}
  end

  defp origin(_, _, _), do: {:error, :invalid_migration_mode}

  defp issue(client, {method, args, body}) do
    with {:ok, response} <- Incus.call(client, method, args, body: body),
         do: Operation.from_response(client, response)
  end

  defp put_body({method, args, body}, key, value),
    do: {method, args, Map.put(Model.encode(body), key, value)}

  defp put_source({method, args, body}, fields) do
    body = Model.encode(body)
    {method, args, Map.put(body, "source", Map.merge(body["source"] || %{}, fields))}
  end

  defp descriptor(client, operation, secrets, origin) do
    %{
      "operation" => origin <> operation.url,
      "websockets" => secrets,
      "certificate" => client.server.environment["certificate"] || ""
    }
  end

  defp secrets(operation) do
    data = Operation.data(operation)["metadata"] || %{}

    if is_map(data) and map_size(data) in 1..16 and is_binary(data["control"]) and
         Enum.all?(data, fn {name, value} ->
           is_binary(name) and byte_size(name) in 1..128 and is_binary(value) and
             byte_size(value) in 1..4096
         end), do: {:ok, data}, else: {:error, %Error{kind: :invalid_migration_secrets}}
  end

  defp failure(state, error, operation) do
    error = if match?(%Error{}, error), do: error, else: %Error{kind: error}

    {:error,
     %Error{
       kind: error.kind,
       operation: error.operation,
       response: %{accepted: state, error: error, operation: operation}
     }}
  end

  @doc "Forward accepted relay channels until EOF or a bounded deadline; does not await backend completion."
  def relay(%__MODULE__{mode: :relay, source: source, target: target} = migration, opts \\ []) do
    timeout =
      opts[:timeout] ||
        min(source.client.connection.stream_timeout, target.client.connection.stream_timeout)

    with true <- is_integer(timeout) and timeout in 1..3_600_000,
         {:ok, source_secrets} <- secrets(source),
         {:ok, target_secrets} <- secrets(target),
         true <- Enum.sort(Map.keys(source_secrets)) == Enum.sort(Map.keys(target_secrets)) do
      opened =
        Enum.reduce_while(Enum.sort(Map.keys(source_secrets)), {:ok, []}, fn name,
                                                                             {:ok, opened} ->
          case Operation.websocket(source, source_secrets[name]) do
            {:ok, left} ->
              case Operation.websocket(target, target_secrets[name]) do
                {:ok, right} ->
                  {:cont, {:ok, [{left, right} | opened]}}

                {:error, error} ->
                  WebSocket.close(left)
                  {:halt, {:error, error, opened}}
              end

            {:error, error} ->
              {:halt, {:error, error, opened}}
          end
        end)

      case opened do
        {:ok, pairs} ->
          forward(migration, pairs, timeout)

        {:error, error, pairs} ->
          close_pairs(pairs)
          failure(migration, error, nil)
      end
    else
      {:error, error} -> failure(migration, error, nil)
      _ -> failure(migration, :invalid_relay, nil)
    end
  end

  defp forward(migration, pairs, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    tasks =
      for {left, right} <- pairs, do: Task.async(fn -> forward_pair(left, right, deadline) end)

    try do
      results = Task.yield_many(tasks, timeout)

      errors =
        Enum.flat_map(results, fn {task, reply} ->
          case reply || Task.shutdown(task, :brutal_kill) do
            {:ok, :ok} -> []
            {:ok, {:error, error}} -> [error]
            _ -> [%Error{kind: :deadline}]
          end
        end)

      case errors do
        [] -> {:ok, migration}
        [error | _] -> failure(migration, error, nil)
      end
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      close_pairs(pairs)
    end
  end

  defp forward_pair(left, right, deadline) do
    tasks = [
      Task.async(fn -> pump(left, right, deadline) end),
      Task.async(fn -> pump(right, left, deadline) end)
    ]

    [left_ref, right_ref] = Enum.map(tasks, & &1.ref)

    try do
      receive do
        {ref, result} when ref == left_ref or ref == right_ref -> result
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          {:error, %Error{kind: :deadline}}
      end
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end

  defp pump(from, to, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, %Error{kind: :deadline}}
    else
      case WebSocket.recv(from, min(remaining, 1000)) do
        {:ok, frame} ->
          with :ok <- WebSocket.send_frame(to, frame), do: pump(from, to, deadline)

        :eof ->
          :ok

        {:error, %Error{kind: :deadline}} ->
          pump(from, to, deadline)

        error ->
          error
      end
    end
  end

  defp close_pairs(pairs),
    do:
      Enum.each(pairs, fn {a, b} ->
        WebSocket.close(a)
        WebSocket.close(b)
      end)
end

defimpl Inspect, for: Opsmaru.Incus.Migration do
  def inspect(_, _), do: "#Opsmaru.Incus.Migration<accepted native handles redacted>"
end
