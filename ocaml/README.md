# nixploy OCaml rewrite

This directory contains the replacement nixploy implementation. The existing
C# CLI and Elixir control plane remain packaged while the OCaml CLI proves each
deployment boundary against currently hosted applications.

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
in SQLite. Secret-bearing targets are rejected until the secrets boundary is
implemented, and this mutating path still needs an isolated no-secret target
before it can replace the existing CLI.

The Bonsai control-plane tracer is served by the second packaged executable:

```console
nixploy-web --port 8080
```

It reads the NixOS-owned `NIXPLOY_MANAGED_APPLICATIONS_JSON` allowlist, displays
the latest persisted deployment for each application, and sends deploy requests
through the same `Tracked_deployment.deploy` path as the CLI. The first slice
serializes web deployments within one process. A durable host lease is required
before CLI and web mutations may safely run concurrently.

Build and test through the repository flake:

```console
nix build .#ocaml-nixploy
nix develop
dune runtest --root ocaml
```

The next tracer is one isolated no-secret deployment initiated from Bonsai and
observed through persisted progress, Caddy compensation, and independent
readback.
