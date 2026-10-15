# opsmaru-incus

Portable native [Incus](https://linuxcontainers.org/incus/) client for Elixir,
used by [Macus](https://github.com/upmaru/macus) and central
[Opsmaru](https://github.com/upmaru/opsmaru).

- **Pure library.** OTP application `:opsmaru_incus`, modules `Opsmaru.Incus.*`,
  `Opsmaru.Incus.Context` and `Opsmaru.Incus.ClientSupervisor`. There is no application
  callback: depending on it starts no process, listener, state or backend
  connection.
- **Explicit connections.** Hosts pass immutable Unix-socket or verified HTTPS
  connection values and a trusted host context on every call. There is no global
  current remote.
- **Native semantics.** Native routes, queries, ETags, error envelopes,
  operation identities and streaming/upgrade protocols are preserved. Possibly
  accepted mutations are never replayed automatically.
- **Traceable coverage.** `priv/incus/coverage.json` maps every declaration of
  the pinned Incus v7.0.1 Go client to implementation and test evidence. This is
  **not yet a complete client port** (`complete_port=false`); see
  [docs/task-3-9-closure.md](docs/task-3-9-closure.md).

## Usage

```elixir
{:opsmaru_incus, git: "https://github.com/upmaru/opsmaru-incus.git", ref: "<immutable revision>"}
```

See [docs/embedding.md](docs/embedding.md) for host context and connection
setup and [docs/incus-client.md](docs/incus-client.md) for the public API.

## Development

```sh
mise trust && mise install
mix deps.get
mise run check            # format, compile, strict Credo, fixtures, OpenSpec
mise run check:reference  # Go inventory/schema verifier and constants
mise run check:consumer   # isolated consumer build of a pushed revision
```

Real Incus acceptance is an explicit opt-in against an isolated backend; see
[docs/real-incus-acceptance.md](docs/real-incus-acceptance.md).

Planning lives in [openspec/](openspec/). Incus reference material is
Apache-2.0; see [priv/notices](priv/notices).

## History

The client was developed inside `upmaru/opsmaru` and extracted with its history
on 2026-10-13 (source revision `a00805d`). Earlier evidence and CI runs are
recorded in [docs/foundation-validation.md](docs/foundation-validation.md).
