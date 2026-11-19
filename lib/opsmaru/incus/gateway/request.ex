defmodule Opsmaru.Incus.Gateway.Request do
  @moduledoc """
  Normalized, bounded request metadata passed to host callbacks.

    * `:protocol` - `:http`, `:websocket` or `:raw` (SFTP/NBD upgrade).
    * `:method` - the HTTP method.
    * `:path` - the original percent-encoded path, exactly as received.
    * `:query` - the original raw query string, exactly as received.
    * `:project`, `:target` - native selections from the raw query, or `nil`.
    * `:all_projects` - whether `all-projects` was requested.
    * `:operation` - the operation ID for `/1.0/operations/{id}...` paths.
    * `:image` - for the exact HTTP routes an Incus server uses with an image
      secret, `%{route: route, fingerprint: fingerprint}`; otherwise `nil`.
      `route` is `:info` (`GET /1.0/images/{fp}?secret=`), `:export`
      (`GET /1.0/images/{fp}/export?secret=`), `:upload` (`POST /1.0/images`
      with one `X-Incus-secret` and one `X-Incus-fingerprint` header) or
      `:wait` (`GET /1.0/operations/{id}/wait?secret=`, with no fingerprint).
      The fingerprint is lowercase hexadecimal. The secret itself is not
      copied here.
    * `:peer` - `%{address: ..., port: ..., certificate: der | nil}` from the
      server adapter.
    * `:authorization` - the caller's `authorization` header, or `nil`. It is
      never forwarded to the backend.
  """

  @enforce_keys [:protocol, :method, :path, :query, :peer]
  defstruct [
    :protocol,
    :method,
    :path,
    :query,
    :project,
    :target,
    :operation,
    :image,
    :peer,
    :authorization,
    all_projects: false
  ]

  @type t :: %__MODULE__{}
end

defimpl Inspect, for: Opsmaru.Incus.Gateway.Request do
  def inspect(request, _),
    do:
      "#Opsmaru.Incus.Gateway.Request<#{request.protocol} #{request.method} credentials redacted>"
end
