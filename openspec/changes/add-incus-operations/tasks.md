# Tasks

Planning only. No durable tasks, target registry or connector work belongs to this change.

## 1. Descriptors and host contract

- [ ] 1.1 Define `Opsmaru.Incus.Operations` descriptors and `all/0`, and resolve the canonical naming scheme; verify stable names/schemas via snapshot tests and that each descriptor calls only public client functions.
- [ ] 1.2 Define the `Opsmaru.Incus.Operations.Host` binding; verify missing/failing callbacks, forged connection/owner input and unauthorized projects deny with zero fake-backend requests.
- [ ] 1.3 Implement scope and destructive-confirmation enforcement; verify read-only callers, missing or mismatched confirmation and wrong scopes cannot reach the backend.

## 2. Operations

- [ ] 2.1 Implement inspection operations; verify native data, list/output bounds and truncation against fixtures.
- [ ] 2.2 Implement instance create/update/state and snapshot create/restore with bounded wait; verify completed, running, failed and uncertain results with native operation identity and no automatic retry.
- [ ] 2.3 Implement deletion operations; verify confirmation, native errors and operation identity.
- [ ] 2.4 Implement bounded guest exec; verify explicit instance, argv/env/stdin/output/duration limits, exit status and truncation without an interactive terminal.
- [ ] 2.5 Implement operation get/wait/cancel; verify local timeout versus remote cancellation and unsupported cancellation reporting.
- [ ] 2.6 Record per-operation client method evidence; verify operations depending on unevidenced client methods are not exported.

## 3. MCP binding

- [ ] 3.1 Add optional `tama_mcp` and `Opsmaru.Incus.MCP.Tools.*`; verify compilation with and without `tama_mcp` and that no process, endpoint or task store starts.
- [ ] 3.2 Verify the binding with TamaMCP conformance helpers and a fixture host server combining shared tools with a host-defined tool; verify scope-filtered discovery, duplicate-name compilation failure and no task advertisement.

## 4. Consumer and acceptance

- [ ] 4.1 Extend the isolated consumer fixture to compose the tools in a host TamaMCP server; verify a clean build from a pushed revision.
- [ ] 4.2 With explicit isolated real-Incus opt-in, exercise inspection, a scoped mutation, exec and operation polling; record evidence separately from fixture, Macus composition and hardware acceptance.
- [ ] 4.3 Document the catalogue, scopes, bounds and host binding.
