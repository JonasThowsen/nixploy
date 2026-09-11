# nixploy OCaml implementation

The active direction is a daemonless CLI. The product and runbook contract lives
in [DEVELOPMENT.md](../DEVELOPMENT.md); the cutover sequence lives in
[ROADMAP.md](../ROADMAP.md). OCaml remains the language: simplify the existing
engine rather than starting another rewrite.

## Current implementation, before removal

- `bin/main.ml` contains direct CLI deployment/status/history and obsolete managed
  transport selection. Its direct deployment path uses a prepared local source.
- `lib/application.mli` is the application boundary. It currently combines useful
  deployment operations with service-only APIs that must be removed.
- `lib/configuration.mli` and `../nix/target.nix` define deployment configuration.
  Named runbook configuration is not implemented yet.
- `lib/deployment.mli`, `lib/podman.mli`, `lib/caddy.mli`, and `lib/secrets.mli`
  expose the working deployment effects and ownership-sensitive operations.
- `lib/source.mli` and `lib/tracked_deployment.mli` cover source preparation and
  tracked execution. Preserve source consistency and interruption evidence.
- `lib/runtime_application.mli` currently resolves runtime containers through
  managed application identity. A CLI runbook needs direct target resolution,
  preserving exact ownership and active Caddy-slot verification.
- `web/`, the RPC protocol, control-plane client, and NixOS service packaging are
  still present. They are removal work, not foundations for new capabilities.

Prune is currently fail-closed. Neither simplifying the product nor removing RPC
authorizes bypassing the existing destructive-operation checks.

## Validation

```bash
nix develop . -c dune runtest --root ocaml
nix build .#nixploy
```

For each implementation slice, inspect the packaged CLI help and exercise its
behavior at real boundaries. Keep tests for ownership, fixed argv, secret-safe
diagnostics, compensation, and concurrency when deleting web-only consumers.
