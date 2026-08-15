# nixploy OCaml rewrite

This directory contains the default nixploy CLI and its Bonsai control-plane
surface. The NixOS service now runs this OCaml package directly. Legacy packages
remain temporarily only as fenced rollback artifacts while their sources await
the archive milestone.

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

The native deployment tracer adds:

```console
nixploy deploy --target production
```

The CLI evaluates and builds the current local flake path, including the current
branch and intentional working-tree changes, matching the pragmatic original
CLI workflow. The web control plane instead requires an explicitly previewed
full commit and materializes that exact immutable revision. Both selections are
typed caller policies passed through `Application` to the same deployment
engine. The local HEAD or immutable commit remains recorded as useful revision
metadata.

The engine builds and loads the image, starts the inactive Podman slot, switches
the owned Caddy route, and independently verifies the result. Every stage and
terminal outcome is recorded in SQLite. Relative secret references are resolved
against the evaluated source root, decrypted with SOPS, installed into remote
Podman through stdin, and mounted as container environment secrets without
placing values in argv or retained errors.

This path has deployed Jomat production in both directions across its blue and
green slots. The runs adopted its established legacy resource identity, ran two
secret-backed pre-start commands, switched the exact Caddy route, independently
verified the result, retired the previous slot, and preserved public health
throughout.

Live scoped inspection and deployment history are available through
`nixploy status --target TARGET` and `nixploy history --target TARGET`. Both are
transport adapters over `Application`; history is bounded and scoped by the
canonical working directory and target.

Scoped cleanup is available through `nixploy prune --target TARGET`. It evaluates
the selected local flake through `Application`, derives the same
repository-bound canonical identity and safe OCaml/C# migration candidates as
deployment, verifies exact container ownership,
removes only resource-prefixed Podman secrets, and deletes the exact Caddy route
for web targets. Non-web prune never contacts Caddy.

The Bonsai control-plane tracer is served by the second packaged executable:

```console
nixploy-web --port 8080
```

It binds to loopback, reads the NixOS-owned
`NIXPLOY_MANAGED_APPLICATIONS_JSON` allowlist, displays the latest persisted
deployment for each application, and sends deploy and prune requests through
the same shared `Application` operations as the CLI. CLI and web mutations share
a cross-process target lease rooted beside the SQLite state database. Persisted
requested/running rows from an interrupted process remain deployment history;
they do not act as live-operation locks after restart.

SQLite also stores resource presence by canonical working directory and target.
A verified deploy records `Present`; prune records `Unknown` before cleanup,
`Absent` after complete cleanup, and leaves `Unknown` after an error because
partial safe cleanup may already have happened. Deployment history is retained
independently. The application card renders these resource states rather than
presenting a historical successful deployment as proof that resources still
exist.

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

The operator surface now previews and confirms an exact Git commit, lists recent
deployments, cancels active deployments cooperatively, searches and follows
bounded logs from the positively identified active container, and reports remote
host health plus per-application resource usage. `Application` owns the active
cancellation registry and runtime source/cache orchestration. Cancellation is
scoped by managed application plus operation id; after a process restart,
persisted interrupted state remains visible but cannot be signalled by the new
process. These workflows use separate polling state so confirmation, filters,
and log search remain stable while runtime observations refresh.

The non-destructive Playwright specification checks open prune-confirmation
layout, accessible controls, mobile overflow, and 44px hit areas. It requires an
externally running control plane via `NIXPLOY_E2E_URL`; the repository does not
currently provide a self-contained Playwright harness, so `dune runtest` and the
package build do not execute it.

Build and test through the repository flake:

```console
nix build .#nixploy
nix develop
dune runtest --root ocaml
```

## NixOS operation and migration

Import `nixosModules.default` and configure `services.nixploy`. The module starts
exactly one `nixploy.service` as the long-lived `nixploy` user, executes
`bin/nixploy-web --port PORT --state-db /var/lib/nixploy/state.sqlite3`, and
keeps HOME/XDG state under `/var/lib/nixploy` for durable Podman connection
configuration. The executable itself hardcodes loopback binding. Managed
applications serialize exactly the JSON accepted by `Managed_application`.

Use `sshIdentityFile`, `sshKnownHostsFile`, `sopsAgeKeyFile`, and
`sopsAgeSshKeyFile` for root-readable deployment credentials. systemd copies
them into the private service credential directory and the module sets only the
environment names read by OCaml. A generated start wrapper reapplies or clears
these credential names and the module-owned auth/origin/application names after
systemd loads `environmentFile`, preventing that file from replacing the module
security boundary. Repositories and any additional `readOnlyPaths` must be
readable by the service Unix identity.

Before switching generations, stop all Phoenix web and worker units. Never run
the old and new deployment engines concurrently. Preserve the `nixploy` user,
repository paths, strict known-host data, SSH keys, SOPS identities, and remote
resource identity. PostgreSQL history is deliberately not imported into the new
SQLite database. A rollback must use the same fence in reverse.

The Phoenix remote protocol and its legacy packages are no longer active
service dependencies. They remain available only for a temporary, explicitly
fenced rollback until the source archive milestone.
