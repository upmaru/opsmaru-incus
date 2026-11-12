defmodule Opsmaru.Incus.SimpleStreams.Download do
  @moduledoc false
  alias Opsmaru.Incus.{Error, SimpleStreams, Transfer, Transport}
  alias Opsmaru.Incus.SimpleStreams.Delta

  def run(client, fingerprint, sinks, opts) do
    with :ok <- sinks(sinks),
         :ok <- options(opts),
         {:ok, image} <- SimpleStreams.lookup(client, fingerprint),
         {:ok, files} <- SimpleStreams.files(client, image.data["fingerprint"]) do
      fingerprint = image.data["fingerprint"]

      result =
        Transport.bounded(
          client.connection.stream_timeout,
          "GET",
          fn ->
            deadline = now() + client.connection.stream_timeout

            with {:ok, result, combined} <- download(client, files, sinks, opts, deadline),
                 do: verify(result, combined, fingerprint)
          end,
          client.connection.request_context
        )

      case result do
        {:error, %Error{} = error} ->
          {:error, %{error | response: %{fingerprint: fingerprint, error: error}}}

        other ->
          other
      end
    end
  end

  defp options(opts) do
    if Keyword.keyword?(opts) and length(opts) <= 1 and
         Keyword.keys(opts) -- [:delta_source] == [] and
         (is_nil(opts[:delta_source]) or is_function(opts[:delta_source], 1)),
       do: :ok,
       else: error(:invalid_delta_arguments, nil)
  end

  defp sinks(sinks) when is_map(sinks) do
    if Map.keys(sinks) -- [:metadata, :rootfs] == [] and
         Enum.any?(Map.values(sinks), &is_function(&1, 1)) and
         Enum.all?(Map.values(sinks), &(is_nil(&1) or is_function(&1, 1))),
       do: :ok,
       else: error(:invalid_arguments, "No file requested")
  end

  defp sinks(_), do: error(:invalid_arguments, "No file requested")

  # Metadata then rootfs, as natively; the delivered bytes of both feed the
  # combined image hash.
  defp download(client, files, sinks, opts, deadline) do
    Enum.reduce_while(
      [{:metadata, "meta"}, {:rootfs, "root"}],
      {:ok, %{}, 0, :crypto.hash_init(:sha256)},
      fn {part, key}, {:ok, acc, total, combined} ->
        case {files[key], sinks[part]} do
          {nil, _} ->
            {:cont, {:ok, acc, total, combined}}

          {_, nil} ->
            {:cont, {:ok, acc, total, combined}}

          {file, sink} ->
            budget = %{
              source: opts[:delta_source],
              deadline: deadline,
              maximum: client.connection.max_stream_bytes - total,
              combined: combined
            }

            case part(client, part, files, file, sink, budget) do
              {:ok, value, combined} ->
                {:cont, {:ok, Map.put(acc, part, value), total + value.size, combined}}

              error ->
                {:halt, error}
            end
        end
      end
    )
    |> case do
      {:ok, result, _, combined} -> {:ok, result, combined}
      error -> error
    end
  end

  # The pinned GetImageFile hashes each part it returned a size for.
  defp verify(result, combined, fingerprint) do
    hash = :crypto.hash_final(combined) |> Base.encode16(case: :lower)

    if hash == fingerprint,
      do: {:ok, result},
      else: error(:native, "Image fingerprint doesn't match. Got #{hash} expected #{fingerprint}")
  end

  defp part(client, :rootfs, files, file, sink, %{source: source} = budget)
       when not is_nil(client.delta_adapter) and is_function(source, 1) do
    %{deadline: deadline, maximum: maximum, combined: combined} = budget

    case delta(files, source) do
      nil -> file(client, file, sink, deadline, maximum, combined)
      {base, delta} -> Delta.run(client, base, delta, file, sink, deadline, maximum, combined)
    end
  end

  defp part(client, _, _, file, sink, budget),
    do: file(client, file, sink, budget.deadline, budget.maximum, budget.combined)

  # Like the pinned DeltaSourceRetriever loop, but deterministic: the first delta,
  # by source fingerprint, whose source the host returns (approved difference).
  defp delta(files, source) do
    files
    |> Enum.flat_map(fn {name, file} ->
      case name do
        "root.delta-" <> fingerprint -> [{fingerprint, file}]
        _ -> []
      end
    end)
    |> Enum.sort()
    |> Enum.find_value(fn {fingerprint, file} ->
      case source.(fingerprint) do
        nil -> nil
        base -> {%{fingerprint: fingerprint, source: base}, file}
      end
    end)
  end

  @doc false
  def file(client, file, sink, deadline, remaining_bytes, combined \\ nil) do
    with :ok <- manifest(file),
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
            do: Process.put(ref, %{hash: :crypto.hash_init(:sha256), combined: combined, size: 0})

          :ok

        {:data, bytes} ->
          state = Process.get(ref)

          if sink.(bytes) == :ok do
            Process.put(ref, %{
              hash: :crypto.hash_update(state.hash, bytes),
              combined: combined && :crypto.hash_update(state.combined, bytes),
              size: state.size + byte_size(bytes)
            })

            :ok
          else
            {:error, :sink_failed}
          end

        :done ->
          state = Process.delete(ref)
          hash = :crypto.hash_final(state.hash) |> Base.encode16(case: :lower)

          # The pinned DownloadFileHash compares the hash only, exactly.
          if hash == file.sha256,
            do:
              {:ok,
               %{
                 value: %{
                   name: List.last(String.split(file.path, "/")),
                   size: state.size,
                   sha256: hash
                 },
                 combined: state.combined
               }},
            else:
              error(
                :native,
                "Hash mismatch for #{SimpleStreams.url(client, file.path)}: #{hash} != #{file.sha256}"
              )
      end

      case Transfer.download_origin_events(%{client | connection: connection}, file.path, handler) do
        {:ok, %{result: %{value: value, combined: combined}}} ->
          {:ok, value, combined}

        {:error, %Error{kind: :native, http_status: status}} when is_integer(status) ->
          not_found(client, file, status)

        error ->
          error
      end
    else
      {:error, _} = error -> error
      _ -> error(:deadline, nil)
    end
  end

  # As natively, a missing file means the cached catalog may be outdated.
  defp not_found(client, file, 404) do
    SimpleStreams.cache_call(client, :invalidate, [])
    error(:native, "Unable to fetch #{SimpleStreams.url(client, file.path)}: resource not found")
  end

  defp not_found(client, file, status) do
    error(
      :native,
      "Unable to fetch #{SimpleStreams.url(client, file.path)}: #{SimpleStreams.status_line(status)}"
    )
  end

  @doc false
  def manifest(file) do
    if is_binary(file.path) and is_integer(file.size) and file.size >= 0 and
         is_binary(file.sha256),
       do: :ok,
       else: error(:invalid_download_manifest, nil)
  end

  defp error(kind, message), do: {:error, %Error{kind: kind, message: message}}
  defp now, do: System.monotonic_time(:millisecond)
end
