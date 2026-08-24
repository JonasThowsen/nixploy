# nixploy OCaml rewrite

This directory contains the default nixploy CLI and its Bonsai control-plane
surface. The NixOS service runs this OCaml package directly. Retired
implementations are preserved under [`../legacy/`](../legacy/README.md) as
read-only references and are not package dependencies.

## Direction

- Project flakes remain the deployment configuration source.
- Project repositories remain local to the nixploy control-plane host.
- The CLI and browser use the same SQLite deployment store and tracked
  deployment function.
- The browser UI uses Bonsai and `Async_rpc_kernel` following the Jane Street
  RPC examples.
- PostgreSQL history from the previous control plane will not be migrated.
- Existing Podman names, labels, and Caddy identities remain stable so running
  applications are not disturbed during the rewrite.

The code follows the module design guidance from Real World OCaml: files define
focused modules, invariant-bearing types are abstract behind `.mli` files, and
interfaces are designed before implementations.

## Tracers

The first tracer was deliberately read-only:

```console
nixploy status --target production
```

It evaluates the current project's `.#nixploy` output, derives the same managed
resource key as the deployed C# CLI, and asks the existing named Podman
connection for containers carrying that exact resource identity. This proves
the Nix, OCaml, CLI, and existing-host identity path without mutating a running
application. This path has been verified against an existing hosted
application.

Local-snapshot preparation remains covered as a non-production library
compatibility path, including tracked working-tree changes and intent-to-add
files while excluding ignored output. The packaged standalone CLI, however,
categorically refuses deploy and prune because a process launched by an
unprivileged user or mount namespace cannot self-attest protected host authority.
Managed mutation goes through the root-started web/RPC daemon with separate
single-use deploy and prune receipts. The control plane requires an explicitly
previewed full commit and materializes that exact immutable revision.

The engine builds and loads the image, starts the inactive Podman slot, switches
the owned Caddy route, and independently verifies the result. Every stage and
terminal outcome is recorded in SQLite. Relative secret references are resolved
against the evaluated source root, decrypted with SOPS, installed into remote
Podman through stdin, and mounted as container environment secrets without
placing values in argv or retained errors. Schema `v0.4` also carries typed
`run.readOnlyBinds`; their absolute normalized paths become fixed `--mount`
argv pairs ending in `ro=true` for both pre-start and application containers.
The deployment checks every source on the remote host before building or
running a container and fails without creating a missing path.

This path has deployed Jomat production in both directions across its blue and
green slots, ran two secret-backed pre-start commands, switched the exact Caddy
route, independently verified the result, retired the previous slot, and
preserved public health throughout.

Live scoped inspection and deployment history are available through
`nixploy status --target TARGET` and `nixploy history --target TARGET`. Both are
transport adapters over `Application`; history is bounded and scoped by the
canonical working directory and target.

Scoped cleanup is available through the managed prune RPC. It evaluates
the selected local flake through `Application`, derives the same
repository-bound identity as deployment, and verifies exact container ownership
before removing resource-prefixed Podman secrets or deleting the exact Caddy
route for web targets. Ownership requires the complete modern
`io.nixploy.managed=true`, project, target, and resource-key labels; legacy
`nixploy.*` ownership labels and partial or mixed substitutes are not accepted.
Deployment reconciliation and status also verify the canonical modern repository
identity. Non-web prune never contacts Caddy.

The Bonsai control-plane tracer is served by the second packaged executable:

```console
nixploy-web --port 8080
```

SIGINT and SIGTERM stop the listener, reject new deploy and prune requests,
interrupt active subprocess groups so compensation can unwind, and allow up to
25 seconds for admitted mutations to drain. A second signal forces immediate
shutdown. The NixOS unit allows 30 seconds before systemd forcefully stops it.
During the local Nix image build, bounded 30-second progress heartbeats reach the
same durable stage history and CLI observer without exposing buffered build
output.

It binds to loopback, reads the root-owned
`/etc/nixploy/managed-applications.json` machine authority shared with the CLI,
displays the latest persisted deployment for each application, and sends deploy
and prune requests through
the same shared `Application` operations as the CLI. CLI and web mutations share
a cross-process target lease rooted beside the SQLite state database. History
from an interrupted process remains visible after local crash reconciliation;
its old row does not act as a live-operation lock after restart.

Before a deploy or prune mutates a target, it holds the exclusive local flock
for the canonical working directory and target and reconciles matching
`requested` or `running` rows left by a dead local process. Such rows become
failed with an `interrupted` event and an explicitly unknown remote outcome;
prior revision, stage, and error evidence is retained. A managed application
may reconcile unkeyed CLI history for its physical scope but never another
managed application's keyed history. A live process still holding the flock is
never reconciled. This is local crash reconciliation only: it neither proves
remote state nor provides distributed target authority, rollback, or readiness
semantics.

SQLite also stores resource presence by canonical working directory and target.
A verified deploy records `Present`; an admitted prune first persists its
canonical candidate snapshot, then binds its single-use receipt to that exact
operation under the target lease before recording `Unknown` or invoking cleanup.
It records `Absent` only after complete cleanup and leaves `Unknown` after an
error because partial cleanup may already have happened. A remote cleanup error
ends in a non-replayable `review` stage. Operation history is retained
independently, so an observer can reopen the durable prune operation rather
than infer resource state from a historical success.

Unset `NIXPLOY_AUTH_MODE` is the explicit local-development default. Set it to
`unrestricted` for an explicitly unrestricted development process or to
`tailscale` with `NIXPLOY_OPERATOR_EMAIL`; any other set value is a startup
error. Static HTTP assets keep this identity policy. Browser WebSocket RPC
upgrades additionally require an `http` or `https` `Origin` whose authority
exactly matches the request `Host`, so same-origin localhost development works
without configuration. When a reverse proxy changes the public authority, set
`NIXPLOY_ALLOWED_ORIGIN` to that one public origin (for example,
`https://nixploy.example.com`). The value must contain only a scheme and
authority: userinfo, paths, queries, fragments, missing/`null` origins, and
suffix matches are rejected. Host names are case-insensitive and explicit
standard ports are equivalent to their `http`/`https` defaults.

The URL-driven operator surface is split into Home (`/`), recognized
applications (`/apps`), one operational application workspace
(`/apps/:key`), and point-in-time target telemetry (`/telemetry`). The browser
parses the path before the first render, uses canonical anchors and the History
API for same-origin navigation, and keeps Back/Forward, the active navigation,
page heading, selected application, and document title synchronized. Authorized
direct requests to these routes receive the same SPA shell; unrelated paths and
missing assets remain genuine 404 responses. Unknown valid application keys keep
their URL and render a not-found state after the server allowlist loads.

The application workspace previews and confirms an exact Git commit, lists
app-scoped deployment history, cancels active deployments cooperatively,
searches and follows bounded logs from the positively identified active
container, and reports remote host health plus per-application resource usage.
`Application` owns the active cancellation registry and runtime source/cache
orchestration. Cancellation is scoped by managed application plus operation id;
after a process restart, persisted interrupted state remains visible but cannot
be signalled by the new process. Resource presence remains independent from
historical deployment success. Application, deployment, log, and metric polls
retain independent per-query last-good observations and label refresh failures
as stale without replacing usable data. Transient confirmations, notices, and
log state are local to the selected application route and never enter the URL.

The non-destructive Playwright specification covers direct routes, History API
navigation, deep-link authorization parity, unknown applications,
canonicalization, preview/prune dismissal, bounded log controls, mobile drawer
focus, overflow, and 44px hit areas. It requires an externally running,
configured control plane via `NIXPLOY_E2E_URL`; the repository does not provide
a self-contained Playwright harness, so `dune runtest` and package builds do not
execute it. Do not treat the browser suite as passed unless that external
control plane was actually available.

Build and test through the repository flake:

```console
nix build .#nixploy
nix develop
dune runtest --root ocaml
```

## NixOS operation and migration

Import `nixosModules.default` and configure `services.nixploy`. The module starts
exactly one `nixploy.service` as the long-lived `nixploy` user, executes
`bin/nixploy-web` through its generated security wrapper, and defaults
`stateDatabasePath` to `/var/lib/nixploy/state.sqlite3`. Set that option to an
existing absolute path when preserving migration state, and ensure its parent is
writable inside the service sandbox. The module keeps HOME/XDG state under
`/var/lib/nixploy` for durable Podman connection configuration. The executable
itself hardcodes loopback binding. Managed
applications serialize exactly the JSON accepted by `Managed_application`.

Use `sshIdentityFile`, `sshKnownHostsFile`, `sopsAgeKeyFile`, and
`sopsAgeSshKeyFile` for root-readable deployment credentials. systemd first
loads them into its root-owned service credential directory. Before exec, the
generated start wrapper copies each configured private identity into the
service's ephemeral runtime directory as a service-owned mode `0600` file;
known-hosts data remains in the systemd credential directory. OCaml therefore
receives private identity paths that satisfy its strict regular-file, ownership,
symlink, and no-group/other-permissions validation without persisting secret
contents. The wrapper reapplies or clears these credential names and the
module-owned auth/origin/application names after systemd loads
`environmentFile`, preventing that file from replacing the module security
boundary or redirecting the ephemeral runtime directory. Root source
credentials should remain read-only and protected.
Production repositories are root-protected Git custody trees and require a
root-owned bounded-fresh evidence manifest binding provenance, a full branch ref,
and its exact commit object. They and any additional `readOnlyPaths` must be
readable by the service Unix identity. Exact root-owned `nonProduction`
contracts are the only local-snapshot exception on a managed host.

Before switching generations, stop all Phoenix web and worker units. Never run
the old and new deployment engines concurrently. Preserve the `nixploy` user,
repository paths, strict known-host data, SSH keys, SOPS identities, and remote
resource identity. PostgreSQL history is deliberately not imported into the new
SQLite database. A rollback must use the same fence in reverse.

The Phoenix remote protocol and all retired packages have been removed from the
active flake. Historical sources remain available only in the read-only legacy
archive; rollback requires selecting an older repository revision and observing
the same no-overlap deployment-engine fence.
