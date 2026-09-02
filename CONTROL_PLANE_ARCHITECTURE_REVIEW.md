# Control-plane architecture review

This review was performed independently before implementation against
`CONTROL_PLANE_ARCHITECTURE.md`, the active OCaml CLI/web/Application modules,
the lifecycle contract, and the Netcup NixOS configuration.

## Findings incorporated into the specification

| Severity | Finding | Specification resolution |
| --- | --- | --- |
| High | SQLite-local locking is not authoritative target leasing. | The lease lifecycle now requires broker acquisition, durable generation/receipt evidence, revalidation under lease, compensation-before-release, and `Requires_review` for ambiguity. |
| High | A client-only handshake can be bypassed. | Capability grants are server-enforced, identity/connection-bound, expiring, and required for every managed RPC. |
| High | Current mutation RPCs do not carry an immutable revision. | Managed deployment now requires application, target, provenance, and full SHA; revision-less mutation is removed. |
| High | Current Netcup source paths use ACL/bind-mounted developer Git data rather than protected production custody. | Root-owned custody, atomic privileged mirror/evidence publication, and production evidence are a migration prerequisite. |
| High | Current metrics probe once per application and have no explicit freshness state. | Endpoint-identity single-flight caching, numeric polling/TTL/error bounds, and `Fresh`/`Stale`/`Unavailable` responses are specified. |
| High | A mutable flake endpoint could redirect operator credentials. | Project flakes select only a protected, locally trusted authority alias; they cannot supply an arbitrary credential destination. |
| Medium | Current CLI uses local state and can execute local deployment effects. | Managed CLI behavior, remote read parity, explicit direct-mode fencing, and process-trace acceptance tests are specified. |
| Medium | Operation-update streaming was unspecified. | The first release uses bounded polling with monotonic operation update sequence; subscriptions are deferred until cursor/backpressure semantics are designed. |
| Medium | Crash ambiguity and review were not durable domain states. | `Requires_review`, evidence, startup reconciliation, and no-takeover rules are specified. |
| Medium | Upgrade and rollback lacked state safeguards. | Backup, forward schema refusal, reconciliation, NixOS generation rollback, and explicit database restore rules are specified. |
| Medium | Legacy local history could bleed into managed history. | Operation origin and exact managed application identity fence managed reads/cancellation; legacy history is archived or separately rendered. |
| Low | Endpoint identity was conflated with display text. | A structured normalized endpoint identity and separate redacted label are required. |
| Low | Observation demand limits were absent. | Fixed 10-second interval, 30-second TTL, 15-second timeout, waiter, output, and diagnostic bounds are specified. |

## Review conclusion

The original direction—one Netcup control plane with web and CLI operator
clients—is sound, but it is safe only with the custody, broker, server-enforced
compatibility, and migration gates now captured in the specification. The
highest-risk implementation order is therefore: protected custody and broker
foundation, server-enforced capability handshake, shared reads, endpoint
observation cache, then immutable managed CLI deployment.
