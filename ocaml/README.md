# nixploy OCaml implementation

The active product is a daemonless CLI. The authoritative contract is
[DEVELOPMENT.md](../DEVELOPMENT.md), and remaining integrated acceptance is tracked
in [ROADMAP.md](../ROADMAP.md). Existing installations have an explicit
[migration guide](../MIGRATION.md).

## Application boundary

```text
CLI -> Application -> deployment / runbook / inspection operations
                            |
                            +-> Git / Nix / SSH / Podman / SOPS / Caddy
                            +-> local SQLite deployment history
```

There are no service APIs, managed admission path, web server, RPC transport, or
background dashboard observers. Cancellation handles and lifecycle operations
belong to the current CLI process, not a persistent service.

- `bin/main.ml` parses deploy, status, logs, history, resources, stop, and
  confirmed prune commands.
  `bin/runbook_commands.ml` implements runbook listing and named execution.
- `lib/application.mli` is the orchestration facade. Parsing and rendering do not
  own deployment effects. Inspection JSON lives in `bin/inspection_output.ml`.
- `lib/deployment_request.mli` defines the abstract `Deployment_request.t`: one
  validated local source/target request, claimed once and bound to its history
  operation. It is not an admission receipt or registry authorization.
- `lib/source.mli`, `lib/deployment.mli`, and `lib/tracked_deployment.mli` preserve
  one prepared source for evaluation, image build, and secret references, with
  process-owned cancellation and local history.
- `lib/configuration.mli`, `../nix/config.nix`, and `../nix/target.nix` define the
  `v0.5` configuration and named runbook argv. Ordinary targets need no authority
  profile; obsolete control-plane configuration is diagnosed by the CLI.
- `lib/runbook.mli` prepares and executes one named command;
  `lib/runbook_runtime.mli` resolves an owned running container, using the owned
  Caddy route for web targets. Execution uses the inspected ID, never a name that
  could resolve to a replacement container.
- `lib/podman.mli`, `lib/caddy.mli`, and `lib/secrets.mli` expose ownership-sensitive
  effects. Legacy unlabelled secrets are retained, not adopted or overwritten.
- `lib/mutation_guard.mli` serializes deploy, prune, and run across clients sharing
  the same remote SSH account/login directory. Its atomic, synced directory under
  `.nixploy-mutations/` covers the project/target across repository identities.
  It is durable uncertainty evidence, not a lease or a machine-local lock.

## Failure semantics

The guard is held across runbook selection and exec. Errors, interruption, or
uncertain transport outcomes retain evidence and block later mutations; there is
no timed expiry, automatic takeover, or replay. This deliberately includes errors
that might precede actual remote application changes. Only a known completed
outcome clears the marker; a release failure requires inspection too. Operators
must reconcile remote effects before manually removing the reported marker.

Runbook outcomes carry both the exact child exit code and optional uncertainty.
A known nonzero command exit is a completed outcome, not grounds for replay or
conversion to a generic CLI failure. Uncertain outcomes preserve the child code
while retaining the marker. Non-interactive stdout/stderr stream separately and
are not retained in history. Interactive commands require a terminal, enable
stdin/TTY explicitly, and may merge output streams.

`lib/stop.mli` takes a target offline: route first, then each owned container with
its restart policy set to `no`. Prune requires explicit confirmation (or a read-only
`--dry-run`) and exact resource ownership, and never removes a route or a running
application. It preflights ownership before removing a stopped target's owned
containers, fully owned secrets, and owned image references, or,
with `--stale`, only what `lib/stale_plan.mli` decides the live deployment no
longer uses. Unlabelled secrets, unowned images, volumes, and data are retained.
`lib/inventory.mli` classifies every nixploy resource on a host against the local
flake; `lib/orphan_prune.mli` removes one undeclared resource key under its own
guard after re-observing the host. Local
history is evidence, not remote authority or health.

## Validation

```bash
nix develop . -c dune runtest --root ocaml
nix build .#nixploy
nix build .#checks.x86_64-linux.config-contract
nix build .#checks.x86_64-linux.cli-package-contract
nix build .#checks.x86_64-linux.cli-vm-smoke
```

These are acceptance commands, not a claim that the final integrated build or VM
check has passed. Inspect packaged help and test real boundaries. Keep focused
tests for source consistency, ownership, argv, secrets, compensation, concurrent
clients, crash evidence, exact exit propagation, terminal behavior, and no replay.
Read the explicit `.mli` interfaces before implementations and follow the
[module-design rules](../.agents/skills/ocaml-application-design/SKILL.md).
