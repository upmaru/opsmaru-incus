# Explicit live gateway acceptance host

`scripts/gateway-acceptance-host.exs` defines the repository-owned acceptance
host runtime. Requiring the file starts nothing. A reviewed, source-owned native
scenario driver calls `OpsmaruGatewayAcceptance.run(config, scenario_fun)` after
an operator supplies an explicit private configuration. The thin
`accept-incus-gateway.exs` entrypoint loads only the fixed repository-owned
`gateway_live_scenarios.exs` module. It strictly parses the explicitly supplied
configuration and verifies CLI provenance, required network selection, clean
source and the pinned Go driver build before creating any backend resource.
Set `OPSMARU_GATEWAY_ACCEPTANCE_CONFIG` to the absolute private configuration
path, then explicitly run `MIX_ENV=test mise exec -- mix run scripts/accept-incus-gateway.exs`.

The runtime never installs or launches Incus, finds a default socket or remote,
modifies backend trust, changes global networks/profiles, retries mutations or
cancels remote operations during cleanup. Failed runs preserve their backend
resources and journal. Starting this acceptance host is independent of loading
the passive library and does not establish installed Macus or hardware evidence.

## Required private configuration

The existing preflight configuration is extended with these fields:

- `allow_namespaced_mutations: true`, pinned `expected_version: "7.0.1"`.
- An unused absolute `report` path and new absolute `state_directory`.
- Separate `source.project` and `target.project` names beginning with
  `opsmaru-acceptance-gateway-`; each must be absent before either is created.
- Each side's explicit `backend` Unix socket or verified HTTPS connection,
  64-character local container image fingerprint, storage pool and verified
  existing managed `network` name. These existing resources remain read-only.
- Absolute `incus_cli` and `incus_cli_provenance` references matching the pinned
  verifier build. Optional `probe_address` is a controlled read-only diagnostic
  candidate, never a replacement migration origin.
- Each side's previously verified `expected_identity.server_name` and
  `expected_identity.certificate_sha256`, checked against authenticated backend
  discovery before any mutation.
- Each side's `gateway.https` origin, literal `bind_ip`, and explicit nonempty
  `allowed_operation_peers` list of literal bootstrap candidate addresses.
  Candidates grant no authority: verified peer state starts empty. The runtime does no
  reachability inference, DNS override or guest-address fallback.
- Absolute `gateway.server_certificate`, `server_key`, `client_certificate`,
  `client_key` and `client_ca` file references. Only the temporary host uses
  these credentials; backend credentials remain separate. Native CLI remotes
  sharing one client configuration normally use the same caller certificate.

The public identity still obeys the gateway's address rules: use an explicitly
approved, resolvable hostname and a certificate valid for it. A private literal
address cannot bypass the existing identity validation. Guest reachability is a
separate check before server-initiated migration, rather than an assumption
inferred from the host interface inventory.

## Execution and evidence

The runtime verifies both server identities, version, selected pool and local
container image, and proves both project names are absent before issuing any
mutation. It journals each project creation before sending it, assigns an
unguessable run description, and checks that marker again. The journal records
the marker, resource prefix, verified backend identities, configuration
fingerprint and host source hash before the first mutation. Fresh projects own
their profiles and volume namespace and share existing images read-only. The
scenario driver supplies explicit per-instance devices; it must not edit global
profiles or networks.

The scenario receives:

```elixir
%{
  config: private_config,
  clients: %{"source" => verified_unscoped_client, "target" => verified_unscoped_client},
  sides: %{
    "source" => %{client: project_scoped_client, origin: https_origin,
      host: ephemeral_host_config, incus_conf: private_side_directory},
    "target" => %{client: project_scoped_client, origin: https_origin,
      host: ephemeral_host_config, incus_conf: private_side_directory}
  },
  marker: run_marker,
  resource_prefix: "gw-<run-specific-value>-",
  runtime: private_state_directory,
  incus_conf: private_shared_cli_directory
}
```

Use names beginning with `resource_prefix`. `step(context, name, fun)` records
intent before calling a fixed, source-owned action, then records its result and
known native operation ID. It stops after an error without cleanup or replay.
It never accepts configured shell commands or dynamically loaded modules.
`record_case(context, case_id, outcome)` accepts only a declared case ID and
`passed`, `native_limitation`, `failed` or `unrun`. No raw bodies, command output,
secrets or credential contents enter the journal. Writes replace the journal
atomically through an exclusive owner-private temporary file.

`record_detail(context, label, safe_map)` records bounded, allowlisted proof
fields such as native operation IDs, byte counts and hashes; it rejects raw
output fields, nested credential fields and private-key markers. Call it before
closing a frontend when testing interruption, so the accepted identity is
available even if subsequent reconciliation fails.

The required ledger contains discovery, enrollment, HTTP, binary transfer, exec,
console, events, SFTP, NBD, denial and interruption, plus copy/move ×
instance/snapshot × relay/pull/push × source/target gateway orientation. Host
mounting alone leaves every case unrun. Missing protocols or native limitations
remain explicit. Only the six user-accepted pinned CLI snapshot-move cases may
satisfy completeness with `native_limitation`; another missing or native-limited
protocol keeps the aggregate report partial. Typed-client coverage, installed host acceptance and Macus
hardware acceptance retain their separate fields.

Both TLS hosts mount the native Plug and Cowboy raw companion on the same
listener. They use only ephemeral caller trust, request client certificates
without requiring one, and enforce an explicit route/method allowlist. A
project query cannot authorize global project, cluster, network or storage-pool
mutations. Instance paths use the run prefix, custom-volume paths use the
selected pool and fresh project, and operation paths require verified IDs.
Enrollment token state stores only a digest and uses constant-time comparison.
Native operation WebSockets may omit the project and server peers may have no
client certificate. A source-owned external poller checks the run marker and
calls verified project-scoped `GetOperations`; it registers only operations
whose instance resources have the run-specific prefix. A special migration
grant additionally requires a pending WebSocket operation, the pinned native
migration description and control/fs channel metadata. The registry discards
secrets, expires entries, and fails closed if polling or marker validation
fails. Policy callbacks consult that local registry under bounded waits and
perform no backend I/O. Special server-peer authority starts empty. The source-owned
`OpsmaruGatewayDaemonProbe.verify_and_activate(context)` helper proves each
actual backend daemon's connection independently: the target daemon connects
to a temporary TLS beacon using the source gateway's configured hostname,
certificate and bind interface, and the source daemon connects to the target
beacon. A fresh namespaced custom filesystem-volume pull-migration request
carries a private operation/secret nonce. The beacon checks both exactly,
records the actual TCP peer and deliberately responds 403. The helper requires
an accepted native operation ID and authoritative terminal failure before
activating that receiver's observed peer with
`set_verified_operation_peers(context, receiver_side, literal_addresses, nonce_sha256)`.
It revalidates the project marker and separate-volume feature before the POST,
records intent and native operation identity, and preserves any owned partial
volume for ordinary successful-run cleanup. It never cancels an operation,
replays the POST, rewrites an origin or performs a global mutation.

An unreachable daemon, wrong nonce, uncertain reply or operation deadline keeps
that receiver unverified and its migration authority empty. Container-origin
connectivity probes remain diagnostic: their DNS, routing or NAT source can
differ from the daemon and cannot authorize either receiving gateway. The
three-argument peer setter remains a compatibility helper for fixtures that
explicitly verify an identical peer on both sides; the real runner uses only
separate per-daemon, per-receiver proofs. These are trusted local policy updates,
not HTTP APIs or forwarded-header inference. Replacing or clearing verified
peer state revokes old grants on the ordinary validity check.

Local watchers close both host listeners and their admission/trust processes on
success, scenario failure or owner loss. Backend resources are retained by this
scaffold. A source-owned scenario may perform separately authorized successful
cleanup only after its declared acceptance conditions hold and after rechecking
the exact run marker; failures must preserve the resources and operation IDs.

After separately authorized successful cleanup, the source-owned scenario calls
`mark_cleaned(context)`. It checks the full case ledger and verifies that both
configured project names now return native 404 before changing the report's
cleanup state. The helper deletes nothing. The final phase says cleaned only
after that verification; partial or failed acceptance cannot be marked clean.
