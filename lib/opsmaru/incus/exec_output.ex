defmodule Opsmaru.Incus.ExecOutput do
  @moduledoc false
  alias Opsmaru.Context
  alias Opsmaru.Incus.{Error, Operation, RequestContext, Session, Transport}

  def collect(%Session{operation: %Operation{} = operation} = session, stdout, stderr, opts) do
    with :ok <- valid_session(session, stdout, stderr),
         {:ok, timeout, limit} <- options(opts, operation.client.connection),
         :ok <- Context.authorize(operation.client.context, operation.client.connection) do
      connection = operation.client.connection
      deadline = RequestContext.deadline(connection.request_context, now() + timeout)

      try do
        Transport.bounded(
          timeout,
          "GET",
          fn -> drain(session, %{"1" => stdout, "2" => stderr}, deadline, limit) end,
          connection.request_context
        )
        |> retain(operation)
      after
        Session.close(session)
      end
    else
      {:error, %Error{} = error} -> retain({:error, error}, operation)
      {:error, kind} -> retain({:error, %Error{kind: kind}}, operation)
    end
  end

  def collect(_, _, _, _), do: {:error, %Error{kind: :invalid_exec_collection}}

  defp valid_session(session, stdout, stderr) do
    if session.owner == self() and session.collectable? and is_function(stdout, 1) and
         is_function(stderr, 1) and is_map(session.channels) and
         map_size(session.channels) in [3, 4] and
         Enum.sort(Map.keys(session.channels)) in [["0", "1", "2"], ["0", "1", "2", "control"]],
       do: :ok,
       else: {:error, :invalid_exec_collection}
  end

  defp options(opts, connection) do
    if Keyword.keyword?(opts) and length(opts) <= 2 and
         Keyword.keys(opts) -- [:timeout, :max_output_bytes] == [] and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) do
      timeout = Keyword.get(opts, :timeout, connection.stream_timeout)
      limit = Keyword.get(opts, :max_output_bytes, connection.max_stream_bytes)

      if is_integer(timeout) and timeout in 1..connection.stream_timeout and
           is_integer(limit) and limit in 1..connection.max_stream_bytes,
         do: {:ok, timeout, limit},
         else: {:error, :invalid_exec_collection}
    else
      {:error, :invalid_exec_collection}
    end
  end

  defp drain(session, sinks, deadline, limit) do
    with :ok <- Session.close_input(session) do
      requests =
        Enum.reduce(["1", "2"], :gen_server.reqids_new(), fn name, requests ->
          read(session, name, deadline, requests)
        end)

      receive_outputs(session, sinks, deadline, limit, requests, %{"1" => 0, "2" => 0})
    end
  end

  defp receive_outputs(session, sinks, deadline, limit, requests, counts) do
    if :gen_server.reqids_size(requests) == 0 do
      finish(session.operation, deadline, counts)
    else
      case :gen_server.wait_response(requests, max(0, deadline - now()), true) do
        {{:reply, {:ok, {:binary, bytes}}}, name, requests} ->
          with :ok <- chunk_budget(session, counts, bytes, limit),
               :ok <- acknowledge(sinks[name], bytes) do
            receive_outputs(
              session,
              sinks,
              deadline,
              limit,
              read(session, name, deadline, requests),
              Map.update!(counts, name, &(&1 + byte_size(bytes)))
            )
          end

        {{:reply, eof}, _, requests} when eof in [:eof, {:ok, {:text, ""}}] ->
          receive_outputs(session, sinks, deadline, limit, requests, counts)

        {{:reply, {:error, %Error{} = error}}, _, _} ->
          {:error, error}

        :timeout ->
          {:error, %Error{kind: :deadline}}

        _ ->
          {:error, %Error{kind: :exec_output_protocol}}
      end
    end
  end

  defp chunk_budget(session, counts, bytes, limit) do
    if counts["1"] + counts["2"] + byte_size(bytes) <= limit and
         byte_size(bytes) <= session.operation.client.connection.max_chunk_bytes,
       do: :ok,
       else: {:error, %Error{kind: :exec_output_limit}}
  end

  defp read(session, name, deadline, requests) do
    :gen_server.send_request(
      session.channels[name].pid,
      {:recv, max(1, deadline - now())},
      name,
      requests
    )
  end

  defp acknowledge(sink, bytes) do
    if sink.(bytes) == :ok, do: :ok, else: {:error, %Error{kind: :sink_rejected}}
  rescue
    _ -> {:error, %Error{kind: :sink_rejected}}
  catch
    _, _ -> {:error, %Error{kind: :sink_rejected}}
  end

  defp finish(operation, deadline, counts) do
    with true <- deadline > now(),
         {:ok, current} <- Operation.wait(operation, timeout: max(1, deadline - now())),
         true <- deadline > now(),
         %{"return" => status} when is_integer(status) <- Operation.data(current)["metadata"] do
      {:ok,
       %{
         operation: current,
         exit_status: status,
         stdout_bytes: counts["1"],
         stderr_bytes: counts["2"]
       }}
    else
      false -> {:error, %Error{kind: :deadline}}
      {:error, error} -> {:error, error}
      _ -> {:error, %Error{kind: :invalid_exec_status}}
    end
  end

  defp retain({:error, error}, operation),
    do:
      {:error,
       %{error | operation: operation.url, response: error.response || operation.response}}

  defp retain(result, _), do: result
  defp now, do: System.monotonic_time(:millisecond)
end
