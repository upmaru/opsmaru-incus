defmodule Opsmaru.Incus.ExecRun do
  @moduledoc false
  alias Opsmaru.Incus

  alias Opsmaru.Incus.{
    Context,
    Error,
    ExecOutput,
    Model,
    Operation,
    RequestContext,
    Response,
    Session,
    Transport
  }

  def run(client, instance, body, stdin, stdout, stderr, opts) do
    body = Model.encode(body)

    with {:ok, timeout, output} <- options(client.connection, body, stdin, stdout, stderr, opts),
         :ok <- Context.authorize(client.context, client.connection) do
      execute(client, instance, body, stdin, stdout, stderr, timeout, output)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp options(connection, body, stdin, stdout, stderr, opts) do
    if valid_input?(body, stdin, stdout, stderr) and valid_options?(opts) do
      timeout = Keyword.get(opts, :timeout, connection.stream_timeout)
      input = Keyword.get(opts, :max_input_bytes, connection.max_stream_bytes)
      output = Keyword.get(opts, :max_output_bytes, connection.max_stream_bytes)

      cond do
        not (is_integer(timeout) and timeout in 1..connection.stream_timeout and
               is_integer(input) and input in 1..connection.max_stream_bytes and
               is_integer(output) and output in 1..connection.max_stream_bytes) ->
          {:error, :invalid_exec_run}

        byte_size(stdin) > input ->
          {:error, :exec_input_limit}

        true ->
          {:ok, timeout, output}
      end
    else
      {:error, :invalid_exec_run}
    end
  end

  defp valid_input?(body, stdin, stdout, stderr),
    do:
      is_map(body) and body["interactive"] in [nil, false] and
        body["record-output"] in [nil, false] and body["wait-for-websocket"] == true and
        is_binary(stdin) and is_function(stdout, 1) and is_function(stderr, 1)

  defp valid_options?(opts),
    do:
      Keyword.keyword?(opts) and length(opts) <= 3 and
        Keyword.keys(opts) -- [:timeout, :max_input_bytes, :max_output_bytes] == [] and
        length(opts) == length(Enum.uniq(Keyword.keys(opts)))

  defp execute(client, instance, body, stdin, stdout, stderr, timeout, output) do
    context = RequestContext.new!(timeout: timeout)

    context = %{
      context
      | deadline: RequestContext.deadline(client.connection.request_context, context.deadline)
    }

    scoped = Incus.with_context(client, context)
    progress = :ets.new(__MODULE__, [:set, :public])

    try do
      result =
        Transport.bounded(
          timeout,
          "GET",
          fn ->
            :ets.insert(progress, {:submitted, true})

            accepted = fn operation ->
              :ets.insert(progress, {:operation, restore(operation, client)})
              :ok
            end

            with {:ok, session} <- Session.exec(scoped, instance, body, accepted) do
              :ets.insert(progress, {:session, session})

              ExecOutput.collect(
                session,
                stdout,
                stderr,
                [timeout: timeout, max_output_bytes: output],
                stdin
              )
            end
          end,
          client.connection.request_context
        )

      case {result, :ets.lookup(progress, :operation)} do
        {{:error, %Error{} = error}, [{_, operation}]} ->
          {:error,
           %{
             restore(error, client)
             | operation: operation.url,
               response: restore(error.response, client) || operation.response
           }}

        {{:error, %Error{kind: kind} = error}, []}
        when kind in [:deadline, :canceled, :request] ->
          {:error,
           if(:ets.member(progress, :submitted), do: %{error | kind: :uncertain}, else: error)}

        {{:ok, result}, _} ->
          {:ok, %{result | operation: restore(result.operation, client)}}

        {other, _} ->
          restore(other, client)
      end
    after
      RequestContext.cancel(context)
      for {_, session} <- :ets.lookup(progress, :session), do: Session.close(session)
      :ets.delete(progress)
    end
  end

  defp restore(%Operation{} = operation, client),
    do: %{operation | client: client, response: restore(operation.response, client)}

  defp restore(%Response{} = response, client), do: %{response | connection: client.connection}
  defp restore(%Error{} = error, client), do: %{error | response: restore(error.response, client)}

  defp restore(%{operation: operation, error: error} = value, client),
    do: %{value | operation: restore(operation, client), error: restore(error, client)}

  defp restore({:error, error}, client), do: {:error, restore(error, client)}
  defp restore(value, _), do: value
end
