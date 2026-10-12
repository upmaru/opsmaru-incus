defmodule Opsmaru.Incus.SimpleStreams.Delta do
  @moduledoc false
  alias Opsmaru.Incus.Error
  alias Opsmaru.Incus.OCI.AdapterCall
  alias Opsmaru.Incus.SimpleStreams.Download

  def run(client, base, delta, rootfs, sink, deadline, maximum) do
    with :ok <- Download.manifest(delta, maximum),
         :ok <- Download.manifest(rootfs, maximum - delta.size) do
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

      AdapterCall.run(adapter_client, request, max(1, deadline - now()), fn request ->
        convert(client, request, sink, maximum)
      end)
    end
  end

  defp convert(client, request, sink, maximum) do
    ref = make_ref()
    worker = self()
    rejected = :atomics.new(1, [])
    Process.put(ref, %{downloaded: false, size: 0, hash: :crypto.hash_init(:sha256)})

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
        do: emit(client, request, ref, rejected, sink, bytes),
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
      {:ok, _} = result ->
        result

      error ->
        reject(rejected)
        error
    end
  end

  defp emit(client, request, ref, rejected, sink, bytes) do
    state = Process.get(ref)

    valid =
      state.downloaded and is_binary(bytes) and
        byte_size(bytes) <= client.connection.max_chunk_bytes and
        state.size + byte_size(bytes) <= request.rootfs.size and now() < request.deadline

    if valid and sink.(bytes) == :ok do
      Process.put(ref, %{
        state
        | size: state.size + byte_size(bytes),
          hash: :crypto.hash_update(state.hash, bytes)
      })

      :ok
    else
      reject(rejected)
    end
  end

  defp finish(:ok, state, hash, rootfs, rejected) do
    if :atomics.get(rejected, 1) == 0 and state.downloaded and state.size == rootfs.size and
         hash == String.downcase(rootfs.sha256),
       do:
         {:ok, %{name: List.last(String.split(rootfs.path, "/")), size: state.size, sha256: hash}},
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
