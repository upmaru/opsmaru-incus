defmodule Opsmaru.Incus.SimpleStreams.CacheAdapter do
  @moduledoc """
  Explicit host-owned catalog cache, the counterpart of the pinned client's
  `CachePath`. Shared code never writes files.

  Entries are index and products JSON bodies named by their file name inside a
  namespace, the hex SHA-256 of the stream URL, as the pinned cache directory
  lays them out. `read/3` returns the body and its age in milliseconds; the
  library applies the expiry (one hour unless `cache_expiry:` says otherwise).
  A fresh entry is used without a request; a failed request or non-200 reply
  falls back to any entry, expired or not; a fresh 200 body replaces it; and a
  404 while downloading an image file invalidates the namespace.

  Failures are ignored as natively: an error or exception from `read/3` is a
  miss and one from `write/4` or `invalidate/2` leaves the result unchanged.
  Callbacks run in the bounded request worker. Fixture success is not installed
  cache acceptance.
  """
  @callback read(term(), String.t(), String.t()) ::
              {:ok, binary(), non_neg_integer()} | :miss | {:error, term()}
  @callback write(term(), String.t(), String.t(), binary()) :: :ok | {:error, term()}
  @callback invalidate(term(), String.t()) :: :ok | {:error, term()}
end
