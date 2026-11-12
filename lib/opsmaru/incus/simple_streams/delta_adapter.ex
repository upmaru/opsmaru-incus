defmodule Opsmaru.Incus.SimpleStreams.DeltaAdapter do
  @moduledoc """
  Explicit host-owned delta conversion. No xdelta runner is bundled.

  Requests carry a unique call identity, absolute monotonic deadline, verified
  connection/context, opaque host base source and native delta/rootfs manifests.
  `download_delta` accepts an acknowledged sink and downloads the verified delta
  once. Call it synchronously before emitting converted rootfs chunks. Stop on
  any failed acknowledgement. All callbacks execute in one bounded worker.

  The host owns tools, credentials, base files and conversion state. Idempotent
  `cleanup/3` must release per-call external resources even if conversion was
  killed mid-creation. Fixture success is not installed-converter acceptance.
  """
  @callback convert(term(), map(), (binary() -> :ok | {:error, term()})) ::
              :ok | {:error, term()}
  @callback cleanup(term(), reference(), atom()) :: :ok | {:error, term()}
end
