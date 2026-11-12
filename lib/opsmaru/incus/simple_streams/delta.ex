defmodule Opsmaru.Incus.SimpleStreams.Delta do
  @moduledoc false
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.OCI.AdapterCall
  alias Opsmaru.Incus.SimpleStreams.Download

  def run(client, base, delta, rootfs, sink, deadline, maximum, combined) do
    with :ok <- Download.manifest(delta),
         :ok <- Download.manifest(rootfs) do
      adapter_client = %{
        connection: client.connection,
        adapter: client.delta_adapter,
        config: client.delta_config
      }

      request = %{
        connection: client.connection,
        context: client.context,
        deadline: deadline,
        base: base,
        delta: delta,
        rootfs: rootfs
      }

      result =
        AdapterCall.run(adapter_client, request, max(1, deadline - now()), fn request ->
          convert(client, request, sink, maximum, combined)
        end)

      case result do
        {:ok, value, combined} ->
          {:ok, value, combined}

        # A cleanup failure keeps the conversion's own result.
        {:error, %Error{kind: :adapter_cleanup, response: {:ok, value, _}} = error} ->
          {:error, %{error | response: {:ok, value}}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp convert(client, request, sink, maximum, combined) do
    ref = make_ref()
    worker = self()
    rejected = :atomics.new(1, [])

    Process.put(ref, %{
      downloaded: false,
      delta_size: 0,
      size: 0,
      hash: :crypto.hash_init(:sha256),
      combined: combined
    })

    download = fn delta_sink ->
      cond do
        self() != worker or :atomics.get(rejected, 1) != 0 -> reject(rejected)
        Process.get(ref).downloaded -> reject(rejected)
        not is_function(delta_sink, 1) -> reject(rejected)
        true -> download(client, request, ref, rejected, delta_sink, maximum)
      end
    end

    emit = fn bytes ->
      if self() == worker and :atomics.get(rejected, 1) == 0,
        do: emit(client, request, ref, rejected, sink, bytes, maximum),
        else: reject(rejected)
    end

    request = Map.put(request, :download_delta, download)
    result = client.delta_adapter.convert(client.delta_config, request, emit)
    state = Process.delete(ref)
    hash = :crypto.hash_final(state.hash) |> Base.encode16(case: :lower)
    finish(result, state, hash, request.rootfs, rejected)
  end

  defp download(client, request, ref, rejected, sink, maximum) do
    # Reserve before the callback to reject repeated/reentrant downloads.
    Process.put(ref, %{Process.get(ref) | downloaded: true})

    case Download.file(client, request.delta, sink, request.deadline, maximum) do
      {:ok, value, _} ->
        Process.put(ref, %{Process.get(ref) | delta_size: value.size})
        {:ok, value}

      error ->
        reject(rejected)
        error
    end
  end

  # Converted bytes share the part's byte budget with the delta download.
  defp emit(client, request, ref, rejected, sink, bytes, maximum) do
    state = Process.get(ref)

    valid =
      state.downloaded and is_binary(bytes) and
        byte_size(bytes) <= client.connection.max_chunk_bytes and
        state.delta_size + state.size + byte_size(bytes) <= maximum and now() < request.deadline

    if valid and acknowledge(sink, bytes) == :ok do
      Process.put(ref, %{
        state
        | size: state.size + byte_size(bytes),
          hash: :crypto.hash_update(state.hash, bytes),
          combined: :crypto.hash_update(state.combined, bytes)
      })

      :ok
    else
      reject(rejected)
    end
  end

  defp acknowledge(sink, bytes) do
    sink.(bytes)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # As natively, converted bytes are checked by the combined image fingerprint,
  # not against the full rootfs manifest.
  defp finish(:ok, state, hash, rootfs, rejected) do
    if :atomics.get(rejected, 1) == 0 and state.downloaded,
      do:
        {:ok, %{name: List.last(String.split(rootfs.path, "/")), size: state.size, sha256: hash},
         state.combined},
      else: {:error, %Error{kind: :delta_failed}}
  end

  defp finish({:error, %Error{}} = error, _, _, _, _), do: error
  defp finish(_, _, _, _, _), do: {:error, %Error{kind: :adapter_failed}}

  defp reject(rejected) do
    :atomics.put(rejected, 1, 1)
    {:error, :delta_rejected}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
