defmodule Opsmaru.Incus.SimpleStreams.Download do
  @moduledoc false
  alias Opsmaru.Incus.{Error, SimpleStreams, Transfer, Transport}

  def run(client, fingerprint, sinks) do
    with :ok <- sinks(sinks),
         {:ok, image} <- SimpleStreams.image(client, fingerprint),
         {:ok, files} <- SimpleStreams.files(client, image.data["fingerprint"]) do
      result =
        Transport.bounded(client.connection.stream_timeout, "GET", fn ->
          download(client, files, sinks, now() + client.connection.stream_timeout)
        end)

      case result do
        {:error, %Error{} = error} ->
          {:error, %{error | response: %{fingerprint: image.data["fingerprint"], error: error}}}

        other ->
          other
      end
    end
  end

  defp sinks(sinks) when is_map(sinks) do
    if Map.keys(sinks) -- [:metadata, :rootfs] == [] and
         Enum.any?(Map.values(sinks), &is_function(&1, 1)) and
         Enum.all?(Map.values(sinks), &(is_nil(&1) or is_function(&1, 1))),
       do: :ok,
       else: error(:invalid_arguments, "No file requested")
  end

  defp sinks(_), do: error(:invalid_arguments, "No file requested")

  defp download(client, files, sinks, deadline) do
    Enum.reduce_while([{:metadata, "meta"}, {:rootfs, "root"}], {:ok, %{}, 0}, fn
      {part, key}, {:ok, acc, total} ->
        case {files[key], sinks[part]} do
          {nil, _} ->
            {:cont, {:ok, acc, total}}

          {_, nil} ->
            {:cont, {:ok, acc, total}}

          {file, sink} ->
            case file(client, file, sink, deadline, client.connection.max_stream_bytes - total) do
              {:ok, value} -> {:cont, {:ok, Map.put(acc, part, value), total + value.size}}
              error -> {:halt, error}
            end
        end
    end)
    |> case do
      {:ok, result, _} -> {:ok, result}
      error -> error
    end
  end

  defp file(client, file, sink, deadline, remaining_bytes) do
    with :ok <- manifest(file, remaining_bytes),
         true <- now() < deadline do
      connection = %{
        client.connection
        | stream_timeout: max(1, deadline - now()),
          max_stream_bytes: remaining_bytes
      }

      ref = make_ref()

      handler = fn
        {:headers, _} ->
          unless Process.get(ref),
            do: Process.put(ref, %{hash: :crypto.hash_init(:sha256), size: 0})

          :ok

        {:data, bytes} ->
          state = Process.get(ref)

          if state.size + byte_size(bytes) <= file.size and sink.(bytes) == :ok do
            Process.put(ref, %{
              hash: :crypto.hash_update(state.hash, bytes),
              size: state.size + byte_size(bytes)
            })

            :ok
          else
            {:error, :checksum}
          end

        :done ->
          state = Process.delete(ref)
          hash = :crypto.hash_final(state.hash) |> Base.encode16(case: :lower)

          if hash == String.downcase(file.sha256) and state.size == file.size,
            do:
              {:ok,
               %{name: List.last(String.split(file.path, "/")), size: state.size, sha256: hash}},
            else: {:error, :checksum}
      end

      with {:ok, transfer} <-
             Transfer.download_origin_events(
               %{client | connection: connection},
               file.path,
               handler
             ),
           do: {:ok, transfer.result}
    else
      {:error, _} = error -> error
      _ -> error(:deadline, nil)
    end
  end

  defp manifest(file, maximum) do
    if is_integer(file.size) and file.size >= 0 and file.size <= maximum and
         is_binary(file.sha256) and Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, file.sha256),
       do: :ok,
       else: error(:invalid_download_manifest, nil)
  end

  defp error(kind, message), do: {:error, %Error{kind: kind, message: message}}
  defp now, do: System.monotonic_time(:millisecond)
end
