# Native Incus gateway (G1: core HTTP relay)

`Opsmaru.Incus.Gateway` lets a host relay native Incus HTTP through its own
endpoint under its own policy. This page documents slice G1 of
`add-embeddable-incus-gateway`; identity rewriting, revocation, WebSockets,
SFTP/NBD and migration arrive in later slices and are listed under
[Not yet in this revision](#not-yet-in-this-revision).

## Dependencies

`plug` and `cowboy` are optional dependencies of `:opsmaru_incus`. A host that
mounts the gateway already has them; a client-only consumer does not and still
compiles warning-free (`Opsmaru.Incus.Gateway.Plug` is simply absent). The
gateway's streaming and abort behaviour is verified with Plug.Cowboy, the
adapter Macus uses.

## Host composition

1. Start an admission process in the host's own supervision tree. The library
   never starts it.

   ```elixir
   children = [
     {Opsmaru.Incus.Gateway.Admission, name: MyHost.GatewayAdmission, max_exchanges: 64},
     MyHostWeb.Endpoint
   ]
   ```

2. Implement `Opsmaru.Incus.Gateway.Host`: `ready?/1` and `authorize/2`.

3. Build the gateway at request time (so runtime configuration and pids are
   never compiled into the router):

   ```elixir
   def fetch do
     Opsmaru.Incus.Gateway.new!(
       connection: MyHost.Incus.connection(),
       host: MyHost.GatewayPolicy,
       host_config: MyHost.GatewayPolicy.config(),
       admission: MyHost.GatewayAdmission
     )
   end
   ```

4. Mount it for the native routes, ahead of any body parser:

   ```elixir
   get "/", Opsmaru.Incus.Gateway.Plug, gateway: {MyHost.Gateway, :fetch, []}
   forward "/1.0", Opsmaru.Incus.Gateway.Plug, gateway: {MyHost.Gateway, :fetch, []}
   ```

   Keep `/runtime`, `/mcp` and other host routes outside these mounts. A gateway
   placed behind `Plug.Parsers` refuses every request with `500` instead of
   relaying a reconstructed body.

## Request path

Every request takes the same path before any backend socket opens:

1. Route check on the original encoded `request_path`: only `/`, `/1.0` and
   `/1.0/*`; dot segments, NUL and backslashes, raw or percent-encoded, are
   refused (`400`). An encoded `/` inside a segment is kept, since image
   aliases use it.
2. Selection parsing on the raw query. Duplicate `project`, `target` or
   `all-projects` values, `;` separators and malformed escapes are refused
   (`400`). The backend parses with Go's `url.ParseQuery` and falls back to
   the default project when the query fails to parse, so the gateway refuses
   exactly those queries to keep the authorized selection and the executed
   one identical. `all-projects` follows the backend's `IsTrue`.
3. Admission: at capacity `503`, nothing queued.
4. `ready?/1`, then `authorize/2`, each in a monitored process killed at
   `callback_timeout`. Anything but `true` / `{:ok, grant}` denies (`503` /
   `403`). A late answer is discarded.
5. Protocol: WebSocket and SFTP/NBD upgrades get `501` in this revision,
   after authorization.

The host receives an `Opsmaru.Incus.Gateway.Request` with the peer address and
TLS certificate from the server adapter, the `authorization` header and the
parsed selection. Body fields and other headers cannot change the principal or
the backend.

## Relay behaviour

- One new backend connection per exchange (Unix or verified mutual HTTPS, from
  the fixed `Connection`); never pooled, retried or redirected.
- The raw path and query are sent unchanged. Statuses, native errors, ETags,
  `Location` operation URLs and bodies are relayed unchanged.
- Never forwarded to the backend: `authorization`, `proxy-authorization`,
  `cookie`, `forwarded`, `x-forwarded-*`, `x-real-ip`, `expect`, hop-by-hop
  fields and fields named in `connection`. `host` comes from the backend
  connection. Everything else, including `x-incus-*`, is forwarded.
- Hop-by-hop response fields are removed. Response fields that could split a
  response are refused before commit. Cowboy writes repeated response fields
  as one comma-joined field.
- Request bodies stream in `max_chunk_bytes` reads; sized bodies keep their
  `content-length`, unsized ones are sent chunked. Response bodies stream with
  backpressure: Cowboy acknowledges each chunk before the next backend read.
- Response trailers are forwarded when the caller sent `TE: trailers` and
  dropped otherwise. Request trailers are not forwarded.

## Failures

Before a response is committed, the gateway answers with a native-shaped error
whose `metadata.gateway.outcome` states what the backend may have seen:

| outcome | meaning |
| --- | --- |
| `not_sent` | No request bytes reached the backend. |
| `sent` | A GET/HEAD was sent and its response failed. |
| `uncertain` | Request bytes may have reached the backend; a mutation may have been accepted. Reconcile with `/1.0/operations` before retrying. |

`metadata.gateway.operation` carries a known operation URL when one was seen.
Timeouts are `504`, backend failures `502`, admission loss `503`. Admission is
checked again before the backend connection opens and before the request is
sent, so an admission that stopped while the host callbacks ran is reported
`not_sent` with no backend contact.

`max_lifetime` and admission are checked before every backend read and before
each chunk is forwarded, so a busy stream with data already queued still stops
at its deadline.

After a response is committed, the gateway cannot send an error. On HTTP/1.x it
ends the caller's Cowboy connection without a final chunk (Ranch logs the
ended connection), so a truncated body is visibly incomplete; on HTTP/2 it
resets the stream. Frontend loss, deadlines and admission restarts close only
gateway-owned sockets. They never send `DELETE` to an operation or replay a
request.

## Limits

| option | default |
| --- | --- |
| `callback_timeout` | 1 s |
| `idle_timeout` | the connection's `stream_timeout` (60 s) |
| `max_lifetime` | 1 hour |
| `max_request_bytes`, `max_response_bytes` | the connection's `max_stream_bytes` (1 GiB) |
| `max_chunk_bytes` | the connection's `max_chunk_bytes` (64 KiB) |
| `max_header_bytes` | 64 KiB |

Long waits such as `/1.0/operations/{id}/wait?timeout=-1` are bounded by
`idle_timeout`; raise it for hosts that need longer waits.

## Not yet in this revision

- `GET /1.0` is relayed unchanged, including the backend's
  `environment.addresses` and certificate. Rewriting them to the gateway's
  public identity, anonymous discovery and certificate enrollment are G2.
- Revocation rechecks for active exchanges are G2.
- WebSocket (G3), SFTP/NBD (G4) and cross-server migration (G5).
- Immutable consumer, CLI conformance and real-Incus gateway acceptance (G6).

Gateway evidence never changes `priv/incus/coverage.json`.
