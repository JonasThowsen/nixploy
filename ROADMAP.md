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

## Operator inspection, cleanup, and reboot survival — complete

Motivated by a host rescale that stopped every container and left resources to be
cleaned up by hand over SSH.

- Application containers run with the `always` restart policy. `deploy` and
  `status` check read-only that the host brings them back (`podman-restart.service`,
  lingering for rootless accounts, Caddy resuming API routes) and name the NixOS
  setting that fixes each gap. A web deploy with no owned route retires the other
  owned slot after a verified switch.
- `status` reports per-container role, state, restarts, CPU, memory, and restart
  policy; the route; secrets; owned images; host-wide Podman storage, free disk and
  capacity; the mutation marker; and derived issues. Supplementary queries degrade
  per section instead of failing the command.
- Deploy tags images into `localhost/nixploy/<resource key>` and drops the archive
  tag, so images are owned. `prune` removes owned images too; `prune --stale` keeps
  the live deployment and removes unserved containers, unmounted owned secrets,
  and owned images beyond `--keep`; `--dry-run` previews either mode.
- `resources` lists every nixploy resource on a target's host by resource key and
  classifies it against the flake; `prune --orphan KEY` removes an undeclared key
  under its own guard after re-verifying ownership.
- `stop` (and `stop --orphan KEY`) removes the route and stops containers with
  restart disabled. Prune never removes a route or a running application and
  refuses a live target; the sequence is stop, then prune.

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
- Inspection and cleanup: the extended VM workflow passed in 1497 seconds
  (`globalTimeout` raised to 2400 for the added steps), covering owned image tags
  with the archive tag removed, the `always` restart policy, status stats, roles,
  route, disk and guard, a no-op `prune --stale` beside a live blue/green target,
  `resources` classification of a target deployed from another checkout and
  renamed away, refusal of `--orphan` for a declared key, prune refusing live
  targets without retaining a guard marker, `stop` removing the route and
  leaving containers stopped with restart disabled, guarded orphan stop and
  removal with the live targets still serving, and prune removing owned images.

The VM driver was built through `checks.x86_64-linux.cli-vm-smoke.driver` and run
directly without KVM. Production migration remains an explicit operator action;
these results do not claim that any existing installation has been migrated.

Do not use production applications implicitly for acceptance. See
[validation commands](DEVELOPMENT.md#delivery-and-validation).

## Deliberately deferred

One-off runbook containers, parameterized commands, and command chaining need a
concrete use case before implementation. Re-applying a lost Caddy route without a
redeploy, systemd/Quadlet units per container, and a `start` command (deploy
restarts a stopped target) wait for a concrete need. Web UI, RPC, Nixploy daemons, application
registries, schedulers, queues, generic workflow engines, and server provisioning
are outside the product boundary, not backlog items.
