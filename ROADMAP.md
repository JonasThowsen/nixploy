# nixploy roadmap

The product contract is [DEVELOPMENT.md](DEVELOPMENT.md): a daemonless deployment
CLI with a small running-container runbook. Historical control-plane plans are
superseded, not parallel product tracks.

## CLI-only cutover and initial runbook — complete

The implementation is integrated and validated. Acceptance used an isolated
NixOS VM, not a production application or existing deployment server.

### Packaged CLI-only product

- Direct deployment is the only path; service APIs, browser/RPC code, managed
  admission machinery, and Nixploy service packaging have been removed.
- Schema `v0.5` supports ordinary declared targets without authority profiles and
  named runbook commands. Obsolete control-plane configuration is diagnosed.
- `Deployment_request` binds one prepared local source to its deployment/history
  operation without a registry or admission receipt.
- `Mutation_guard` coordinates deploy, prune, and run with durable remote markers
  for clients using the same SSH account/login directory. Failures retain evidence
  conservatively; recovery is manual, without expiry or automatic takeover.
- [MIGRATION.md](MIGRATION.md) covers existing installations and legacy unlabelled
  secrets, which are retained and never automatically overwritten.

### Running-container runbook

- Local listing and named execution use literal argv, inspected container IDs,
  and owned active Caddy-slot selection for web targets.
- Execution preserves child exit codes and non-interactive stdout/stderr streams,
  requires an attached terminal for interactive commands, and never replays an
  uncertain command. Command output is not stored in deployment history.
- Selection and exec hold the same remote guard as deploy/prune.

### Small operator surface

- Deploy, status, bounded logs, local history, runbook listing, and confirmed
  `prune --yes` expose structured output; `run` streams application output.
- Prune checks exact ownership and removes owned containers, fully owned secrets,
  and configured owned routes, retaining unlabelled secrets, images, volumes, and data.

## Acceptance results

- Full OCaml suite, packaged CLI build, configuration and command-contract checks
  passed, including help, JSON, exit codes and obsolete-configuration refusal.
- The isolated VM workflow passed in 784 seconds using software virtualization:
  non-web deployment, SOPS-backed pre-start, literal runbook argv, exit 42,
  terminal verification and shell console, cross-checkout mutation contention,
  two Caddy blue/green deployments, exact active-container execution, inspection,
  logs and confirmed cleanup. The unrelated Caddy route remained available.
- Process-boundary tests cover independent-client SIGKILL/orphan effects, retained
  uncertainty, exit 125/255 preservation, no replay, ownership failures, partial
  cleanup, legacy-secret retention, source consistency and bounded compensation.
- Interactive regressions cover blocked-flush cancellation, descendant cleanup,
  double-signal shutdown and terminal restoration.

The VM driver was built through `checks.x86_64-linux.cli-vm-smoke.driver` and run
directly without KVM. Production migration remains an explicit operator action;
these results do not claim that any existing installation has been migrated.

Do not use production applications implicitly for acceptance. See
[validation commands](DEVELOPMENT.md#delivery-and-validation).

## Deliberately deferred

One-off runbook containers, parameterized commands, and command chaining need a
concrete use case before implementation. Web UI, RPC, Nixploy daemons, application
registries, schedulers, queues, generic workflow engines, and server provisioning
are outside the product boundary, not backlog items.
