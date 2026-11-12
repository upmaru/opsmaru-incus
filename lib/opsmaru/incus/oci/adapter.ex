defmodule Opsmaru.Incus.OCI.Adapter do
  @moduledoc """
  Explicit host boundary for OCI inspection and conversion. No runner is bundled.

  `inspect_image/2` returns skopeo-compatible JSON. `image_file/3` calls the
  supplied synchronous emitter with `:metadata` or `:rootfs` and a binary chunk,
  stops on any non-`:ok` acknowledgement and returns `:ok` only on completion.
  Requests contain a unique `call_id`, verified connection/context, normalized
  alias and absolute monotonic `deadline`. Opaque configuration stays host-owned.

  The host must verify registry TLS, isolate credentials, bound subprocesses,
  and own all conversion files. `cleanup/3` is idempotent for a call identity;
  it must work even if the callback was killed before resource creation finished.
  It must finish within the cleanup budget and never cancel other calls or Incus
  workloads. The library invokes it on success, failure, deadline and owner loss.
  Fixture adapters do not establish installed conversion/TLS acceptance.
  """
  @callback inspect_image(term(), map()) :: {:ok, binary()} | {:error, term()}
  @callback image_file(term(), map(), (atom(), binary() -> :ok | {:error, term()})) ::
              :ok | {:error, term()}
  @callback cleanup(term(), reference(), atom()) :: :ok | {:error, term()}
end
