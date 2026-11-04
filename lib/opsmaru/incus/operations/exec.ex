defmodule Opsmaru.Incus.Operations.Exec do
  @moduledoc false
  # Bounded, noninteractive guest exec through the public Session API.
  #
  # Stdin is sent before collection. Each sink keeps the first 64 KiB of its
  # stream and counts the rest. When the duration expires, or total output
  # passes 64 MiB, a short-lived process linked to this call sends SIGKILL once
  # over the control channel; collection then has a 5 s grace to observe the
  # exit. Closing local channels never cancels the Incus operation.
  alias Opsmaru.Incus.{Error, Operation, Session}
  alias Opsmaru.Incus.Operations.{Descriptor, Mutation, Result}
  import Opsmaru.Incus.Operations.Fragments

  @capture 65_536
  @stdin 65_536
  @drain 67_108_864
  @grace 5_000
  @kill 9

  def descriptors do
    [
      %Descriptor{
        name: "incus_instance_exec",
        title: "Run a command in an instance",
        description:
          "Run one noninteractive command in a named instance with bounded stdin, captured output and duration. Output beyond 64 KiB per stream is counted and truncated; a command still running at the timeout is killed.",
        scope: "incus.exec",
        input_schema:
          object(
            %{
              "project" => project(),
              "instance" => name("Instance to run in."),
              "command" => %{
                "type" => "array",
                "minItems" => 1,
                "maxItems" => 64,
                "items" => %{"type" => "string", "maxLength" => 4096},
                "description" => "Argument vector; no shell is implied."
              },
              "environment" => %{
                "type" => "object",
                "maxProperties" => 64,
                "propertyNames" => line(256, "Variable name."),
                "additionalProperties" => %{"type" => "string", "maxLength" => 4096}
              },
              "cwd" => %{
                "type" => "string",
                "maxLength" => 4096,
                "pattern" => "^/[^\\x00]*$",
                "description" => "Absolute working directory inside the instance."
              },
              "user" => %{"type" => "integer", "minimum" => 0, "maximum" => 4_294_967_295},
              "group" => %{"type" => "integer", "minimum" => 0, "maximum" => 4_294_967_295},
              "stdin" =>
                text(@stdin, "UTF-8 standard input (at most 64 KiB), closed after sending."),
              "timeout_seconds" => %{
                "type" => "integer",
                "minimum" => 1,
                "maximum" => 300,
                "default" => 30,
                "description" =>
                  "Duration limit (default 30). Capped by the host stream timeout; the result reports the effective limit."
              }
            },
            ["instance", "command"]
          ),
        output_schema:
          mutation_output(
            Map.merge(stream_fields("stdout") |> Map.merge(stream_fields("stderr")), %{
              "exit_status" => %{"type" => ["integer", "null"]},
              "timed_out" => %{"type" => "boolean"},
              "output_limited" => %{"type" => "boolean"},
              "timeout_seconds" => %{"type" => "integer"}
            })
          ),
        bounds: %{
          "max_input_bytes" => 1_048_576,
          "max_output_bytes" => 262_144,
          "max_args" => 64,
          "max_env" => 64,
          "max_stdin_bytes" => @stdin,
          "max_capture_bytes" => @capture,
          "max_stream_bytes" => @drain,
          "default_timeout_seconds" => 30,
          "max_timeout_seconds" => 300,
          "kill_grace_seconds" => div(@grace, 1000)
        },
        requires: ["ExecInstance", "stream:S01"],
        check: fn input ->
          if byte_size(Map.get(input, "stdin", "")) <= @stdin,
            do: :ok,
            else: {:error, "/stdin", "exceeds 65536 bytes"}
        end,
        run: &run/3
      }
    ]
  end

  defp stream_fields(name),
    do: %{
      name => %{"type" => "string"},
      (name <> "_encoding") => %{"type" => "string", "enum" => ["utf-8", "base64"]},
      (name <> "_bytes") => %{
        "type" => "integer",
        "description" => "Bytes produced, including discarded ones."
      },
      (name <> "_truncated") => %{"type" => "boolean"}
    }

  defp run(client, input, _env) do
    connection = client.connection

    duration =
      min(Map.get(input, "timeout_seconds", 30) * 1000, connection.stream_timeout - @grace)

    if duration < 1000 do
      Result.error("invalid_input", "the host stream timeout is too short for exec")
    else
      case Session.exec(client, input["instance"], body(input)) do
        {:ok, session} ->
          collect(session, input, duration)

        {:error, %Error{kind: :uncertain} = error} ->
          {:ok, empty(Mutation.uncertain(error), duration)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # user/group/cwd need an extension only when set, as natively.
  defp body(input) do
    %{
      "command" => input["command"],
      "wait-for-websocket" => true,
      "interactive" => false,
      "record-output" => false,
      "environment" => Map.get(input, "environment", %{}),
      "width" => 0,
      "height" => 0
    }
    |> Map.merge(Map.take(input, ["user", "group", "cwd"]))
  end

  defp collect(session, input, duration) do
    connection = session.operation.client.connection
    table = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(table, [{"1", 0, []}, {"2", 0, []}, {:killed, false}, {:limited, false}])
    killer = killer(session, table, duration)
    cap = min(@drain, div(connection.max_stream_bytes, 2))

    try do
      result =
        with :ok <- send_stdin(session, Map.get(input, "stdin", ""), connection.max_chunk_bytes) do
          Session.collect(session, sink(table, "1", cap, killer), sink(table, "2", cap, killer),
            timeout: duration + @grace,
            max_output_bytes: connection.max_stream_bytes
          )
        end

      outcome(result, session, table, duration)
    after
      Process.unlink(killer)
      Process.exit(killer, :kill)
      Session.close(session)
      :ets.delete(table)
    end
  end

  defp send_stdin(_session, "", _chunk), do: :ok

  defp send_stdin(session, bytes, chunk) do
    size = min(byte_size(bytes), chunk)
    <<head::binary-size(size), rest::binary>> = bytes

    with :ok <- Session.input(session, head), do: send_stdin(session, rest, chunk)
  end

  # Sinks run in the client's collection process; state lives in the table.
  defp sink(table, name, cap, killer) do
    fn bytes ->
      [{_, count, kept}] = :ets.lookup(table, name)
      room = max(0, @capture - min(count, @capture))
      keep = binary_part(bytes, 0, min(room, byte_size(bytes)))

      :ets.insert(
        table,
        {name, count + byte_size(bytes), if(keep == "", do: kept, else: [kept, keep])}
      )

      if total(table) > cap and not flag(table, :limited) do
        :ets.insert(table, {:limited, true})
        send(killer, :kill)
      end

      :ok
    end
  end

  defp total(table),
    do: elem(hd(:ets.lookup(table, "1")), 1) + elem(hd(:ets.lookup(table, "2")), 1)

  defp killer(session, table, duration) do
    spawn_link(fn ->
      receive do
        :kill -> :ok
      after
        duration -> :ets.insert(table, {:killed, true})
      end

      Session.signal(session, @kill)
    end)
  end

  defp outcome(result, session, table, duration) do
    base =
      Map.merge(stream(table, "1", "stdout"), stream(table, "2", "stderr"))
      |> Map.merge(%{
        "timed_out" => flag(table, :killed),
        "output_limited" => flag(table, :limited),
        "timeout_seconds" => div(duration, 1000),
        "waited_seconds" => div(duration, 1000),
        "operation_id" => Result.operation_id(session.operation.url),
        "wait_error" => nil
      })

    case result do
      {:ok, %{operation: operation, exit_status: status}} ->
        native = Operation.data(operation)

        {:ok,
         Map.merge(base, %{
           "status" => Result.operation_status(native),
           "operation" => native,
           "exit_status" => status
         })}

      {:error, %Error{kind: :operation_failed} = error} ->
        {:ok,
         Map.merge(base, %{
           "status" => "failed",
           "operation" => native(error),
           "exit_status" => nil
         })}

      {:error, %Error{kind: kind} = error}
      when kind in [:deadline, :canceled, :exec_output_protocol, :invalid_exec_status] ->
        {:ok,
         Map.merge(base, %{
           "status" => "running",
           "operation" => native(error) || Operation.data(session.operation),
           "exit_status" => nil,
           "wait_error" => Atom.to_string(kind)
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  defp native(%Error{response: %{metadata: _} = response}), do: Result.native(response)
  defp native(_), do: nil

  defp flag(table, key), do: :ets.lookup(table, key) == [{key, true}]

  defp stream(table, key, name) do
    [{_, count, kept}] = :ets.lookup(table, key)
    {text, encoding} = encode(IO.iodata_to_binary(kept), count > @capture)

    %{
      name => text,
      (name <> "_encoding") => encoding,
      (name <> "_bytes") => count,
      (name <> "_truncated") => count > @capture
    }
  end

  # A cut may split a UTF-8 sequence; drop up to three trailing bytes before
  # falling back to base64.
  defp encode(bytes, truncated?) do
    trimmed = if truncated?, do: trim(bytes, 3)

    cond do
      String.valid?(bytes) -> {bytes, "utf-8"}
      trimmed -> {trimmed, "utf-8"}
      true -> {Base.encode64(bytes), "base64"}
    end
  end

  defp trim(_bytes, 0), do: nil

  defp trim(bytes, n) when byte_size(bytes) > 0 do
    shorter = binary_part(bytes, 0, byte_size(bytes) - 1)
    if String.valid?(shorter), do: shorter, else: trim(shorter, n - 1)
  end

  defp trim(_, _), do: nil

  defp empty(result, duration),
    do:
      Map.merge(result, %{
        "stdout" => "",
        "stdout_encoding" => "utf-8",
        "stdout_bytes" => 0,
        "stdout_truncated" => false,
        "stderr" => "",
        "stderr_encoding" => "utf-8",
        "stderr_bytes" => 0,
        "stderr_truncated" => false,
        "exit_status" => nil,
        "timed_out" => false,
        "output_limited" => false,
        "timeout_seconds" => div(duration, 1000)
      })
end
