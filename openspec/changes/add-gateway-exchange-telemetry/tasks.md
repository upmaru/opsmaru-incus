# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Telemetry evidence is never typed-client, completion-record, differential or gateway acceptance evidence and changes no `priv/incus/coverage.json` entry.

## 1. Emitter and observer

- [ ] 1.1 Add `{:telemetry, "~> 1.3", optional: true}` and `Opsmaru.Incus.Telemetry` with compile-time no-op selection (or extend it if `add-incus-telemetry` has landed). Verify that the client-only consumer compiles without `:telemetry`, that loading the library and calling `Gateway.new!/1` create no process, ETS table or handler in both builds, and that a loaded but unstarted `:telemetry` never raises into a request.
- [ ] 1.2 Add `Opsmaru.Incus.Gateway.Exchange`: `start/1`, the recording functions, `transfer/2`, `finish/2` and the observer that emits `:stop` once on finish or on the owner's `:DOWN`. Verify exactly one stop per start for a normal finish, a killed owner, a finish racing a kill and a transfer followed by a kill; that no observer is spawned when no handler is attached; and that a handler attached mid-exchange produces no unpaired stop.
- [ ] 1.3 Give `Failure` a required internal closed `reason` and set it at every construction site. Verify that `Failure.encode/1` output is byte-identical to before for every failure, that every documented reason is produced by some test and that no undocumented reason exists.

## 2. Emission points

- [ ] 2.1 Emit from `Gateway.Plug` for requests refused before admission, `Local.serve/4` and `HTTPRelay.relay/4`, with byte counts from the relay's existing counters and the status at the response head. Verify the stop event for a relayed read, a relayed mutation, a native error status, each pre-admission refusal (unresolved gateway, parsed body, ambiguous authorization, invalid path, invalid selection, capacity, host not ready, unauthorized, unsupported protocol), anonymous discovery, a trust action, a response aborted after its head, a caller disconnect, and an interrupted mutation reporting `:uncertain`.
- [ ] 2.2 Emit from the WebSocket path, transferring ownership to `WebSocketRelay` at commit. Verify a failed upgrade (finished in the Plug process, no transfer), a normal close from each side, a backend loss, revocation, admission stop, idle and lifetime expiry and a `:kill` of the relay, each with the documented reason and frame payload byte counts.
- [ ] 2.3 Emit from `Gateway.CowboyHandler` and `RawRelay`, transferring ownership at handoff. Verify a rejected raw upgrade, an invalid route, a completed SFTP and NBD tunnel closed by each side, revocation, lifetime expiry and a killed actor, and that requests passed to the host's fallback handler emit nothing from this module.
- [ ] 2.4 Verify that with a raising handler and with a handler that blocks past the idle timeout, every scenario in 2.1 to 2.3 produces the same wire bytes, statuses and admission slot releases as with no handler, and that the backend socket closes without waiting for the handler.

## 3. Redaction

- [ ] 3.1 Add a fixture test that attaches to both events across the gateway fixture suite and fails if any metadata value contains a fixture `authorization` value, query string, operation or image secret, header, body byte, grant, host configuration, backend address or failure message, or a path that `Policy.route/1` refused.
- [ ] 3.2 Verify `peer_fingerprint` equals the SHA-256 of the presented certificate and is `nil` without one, and that `project`, `target`, `all_projects` and `operation` equal the parsed `Request` fields.

## 4. Documentation and consumer verification

- [ ] 4.1 Document the catalogue, closed value sets, the emitting process per event, the excluded values and the handler contract in `docs/gateway.md` and the `Opsmaru.Incus.Telemetry` moduledoc. Verify with a test that every documented event name is emitted and no undocumented `[:opsmaru_incus, :gateway | _]` event is.
- [ ] 4.2 Extend the isolated host consumer (`test/consumer`) to attach a handler and observe one relayed HTTP exchange and one refusal, and assert that `test/consumer/client_only` resolves no `:telemetry`. Verify both with `mise run check:consumer`.
- [ ] 4.3 Narrow the "Gateway relay" scenario of `add-incus-telemetry` to its own request and channel events when that change is next refreshed, and record the shared emitter there.
- [ ] 4.4 Add the CHANGELOG entry and run `mise run check` and `mise run check:reference`. Record that this change adds no real-Incus, gateway acceptance or Macus hardware evidence.
