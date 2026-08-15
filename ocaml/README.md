# nixploy OCaml rewrite

This directory contains the default nixploy CLI and its Bonsai control-plane
surface. The C# CLI remains packaged as `legacy-nixploy` only for the existing
Phoenix remote-adapter path while that separate integration is retired.

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

It resolves the exact local `refs/heads/main`, builds and loads an immutable
Nix image, starts the inactive Podman slot, switches the owned Caddy route, and
independently verifies the result. Every stage and terminal outcome is recorded
in SQLite. Secret references are decrypted with SOPS, installed into remote
Podman through stdin, and mounted as container environment secrets without
placing values in argv or retained errors.

This path has deployed Jomat production in both directions across its blue and
green slots. The runs adopted its established legacy resource identity, ran two
secret-backed pre-start commands, switched the exact Caddy route, independently
verified the result, retired the previous slot, and preserved public health
throughout.

Scoped cleanup is available through `nixploy prune --target TARGET`. It evaluates
the selected local flake through `Application`, adopts the same canonical or
legacy resource identity as deployment, verifies exact container ownership,
removes only resource-prefixed Podman secrets, and deletes the exact Caddy route
for web targets. Non-web prune never contacts Caddy.

The Bonsai control-plane tracer is served by the second packaged executable:

```console
nixploy-web --port 8080
```

It binds to loopback, reads the NixOS-owned
`NIXPLOY_MANAGED_APPLICATIONS_JSON` allowlist, displays the latest persisted
deployment for each application, and sends deploy requests through the same
`Tracked_deployment.deploy` path as the CLI. CLI and web mutations share a
cross-process target lease rooted beside the SQLite state database.

The operator surface now previews and confirms an exact Git commit, lists recent
deployments, cancels active deployments cooperatively, searches and follows
bounded logs from the positively identified active container, and reports remote
host health plus per-application resource usage. These workflows use separate
polling state so confirmation, filters, and log search remain stable while
runtime observations refresh.

Build and test through the repository flake:

```console
nix build .#nixploy
nix develop
dune runtest --root ocaml
```

The remaining legacy boundary is the Phoenix remote CLI protocol. It continues
to use `legacy-nixploy`; direct-main CLI and Bonsai deployments are fully OCaml.
