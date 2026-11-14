# Tasks

The fixture baseline is complete. Remaining items require implementation and verification. The subscription protocol gates the waiter conversions. Typed-client coverage claims and Macus hardware acceptance retain their existing evidence requirements.

## 1. Baseline

- [x] 1.1 Measure process CPU, scheduler active wall time, cancellation-waiter scheduler entries and cancellation latency on macOS and Linux for 1, 100 and 1,000 idle event listeners and SFTP sessions, plus a waiting operation and a pending OCI adapter call. Include cases with and without a host context and a no-workload control. Record the results and decision to proceed in [the design](design.md#1-polling-baseline).

## 2. Subscription protocol

- [x] 2.1 Prototype and prove registration and delivery with deterministic barriers. Cover cancellation before, during and after registration, concurrent cancels, explicit cancellation racing owner exit and deadline, and notifier exit immediately after the terminal transition or during delivery. Pending waits must observe one terminal outcome without periodic checks or another cancel call.
- [x] 2.2 Prove resource reclamation for both creator and context-owner exit orders, including when the creator stays alive and the context never receives a subscriber. Cover completed, cancelled and expired waits, as well as a deadline-tightened private context copy. Verify that construction creates no process, socket or file.
- [x] 2.3 Verify teardown when a notification is in flight or already queued. Deactivate the subscription, drain its messages, release its monitors and preserve unrelated mailbox traffic. Confirm status and terminal precedence match the existing implementation. Record the verified protocol, then update context validation, lifecycle docs and redacted inspection as needed.

## 3. Event-driven waiters

- [x] 3.1 Convert `Transport.guard_until/5`. Verify worker termination and existing results on explicit cancellation, context-owner exit, caller exit and deadline. Add fixture barriers for #29's HTTPS pool at queued checkout, active socket use and ownership return. Verify the next request can still use the pool, preserve unpooled results and prevent replay of possibly accepted mutations.
- [x] 3.2 Convert `Transport.watch_until/4` and remove `tick/2`. Verify closure kinds for each channel type, the 100 ms caller-exit grace and idle behavior. Preserve the monitor-only path for a context-free watcher such as the gateway WebSocket writer's.
- [ ] 3.3 Convert `Operation.sleep_until/2`. Verify native refresh cadence, cancellation and deadline results, no backend `DELETE`, and mailbox cleanup when cancellation races a refresh, timeout or return.
- [ ] 3.4 Convert `OCI.AdapterCall.await_result/6` for OCI and SimpleStreams delta calls. Verify completion races, existing outcomes for cancel, deadline and owner loss, prompt worker termination, and exactly-once per-call cleanup.

## 4. Internal contexts

- [ ] 4.1 Replace the SFTP lifetime context with an absolute deadline and session timer. Verify #29's startup deadline across upgrade and version exchange, plus lifetime expiry, owner loss, lock waits and dispatched mutation uncertainty. Verify local expiry leaves the shared host context active and that SFTP without a host context has no context watcher.
- [ ] 4.2 Verify `ExecRun` releases its private context on all exit paths, including for the deadline-tightened copy. Preserve native results, output limits and uncertainty reporting.

## 5. Verification

- [ ] 5.1 Repeat the baseline on both platforms and record the results side by side. Verify zero periodic context-waiter scheduler entries in the idle windows, including SFTP without a host context. Confirm native refreshes and independent I/O timers still run. Compare process CPU and cancellation latency distributions within each platform.
- [ ] 5.2 Run `mise run check`, `mise run check:reference`, `mise run check:consumer`, and strict OpenSpec validation against the immutable pushed draft revision. When draft #69's executors are ready, run their focused binding and cancellation fixtures against the combined revisions.
