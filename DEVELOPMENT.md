# nixploy development direction

## Product contract

nixploy is a daemonless CLI for deploying and operating applications defined in
Nix. Run it from an application's repository on a laptop or CI runner against an
already-provisioned remote server. The project flake is the configuration source;
SSH is the transport; Podman runs the application; SOPS supplies secrets; Caddy
optionally routes application HTTP traffic.

This contract supersedes the control-plane, browser, and Production V1 plans.
The CLI-only implementation is integrated and its acceptance results are
recorded in [ROADMAP.md](ROADMAP.md). Existing installations must follow
[MIGRATION.md](MIGRATION.md); source cleanup does not migrate live services.

### Keep

- Nix image evaluation, builds, and remote image loading.
- Explicit deployment targets and stable repository/project/target ownership.
- SOPS dotenv secrets, fixed pre-start argv, and existing runtime configuration.
- Non-web container replacement and Caddy blue/green web deployments.
- Health checks, bounded failure recovery, and honest reporting of uncertainty.
- Scoped status, logs, cleanup, and small local history where useful.
- Named runbook commands executed inside the running application container.

### Outside the product

- The Nixploy web UI, HTTP server, browser authentication, and RPC transport.
- The Nixploy service and managed-application registration requirement.
- Managed checkouts, custody records, authority aliases, and preview receipts
  whose purpose was centralized deployment admission.
- Dashboard telemetry, background observers, queues, schedulers, and plugins.

There is no Nixploy daemon on either the operator machine or the target. The
target's existing Podman service and optional Caddy service are still required.
Server provisioning is outside the deployment CLI's scope.

## CLI contract

The command surface is:

```console
nixploy deploy --target production
nixploy status --target production
nixploy logs --target production
nixploy history --target production
nixploy prune --target production --yes
nixploy runbook --target production
nixploy run --target production migrate
```

Every command takes an explicit target from the project flake. Direct execution
is the only deployment mode, not an override or a less-trusted fallback. A normal
deployment requires no root-owned application registry or Nixploy service.

Use `--directory` (`-C`) to select the checkout and `--target` (`-t`) to select the
target. Deploy, status, logs, history, prune, and runbook listing support `--json`;
`run` streams command output and has no JSON wrapper. Diagnostics and deployment
progress go to stderr. Preparation failures produce no deployment result object.
Deploy/status/logs/history/prune accept `--state-db` for local SQLite history and
uncertainty evidence; runbook listing and execution do not open history.

Exit codes are 0 for success, 1 for operation or command-parser errors, 2 for an
invalid target or missing prune confirmation, and 130 for interruption of a
started deployment. Runbook execution propagates the child exit code exactly rather
than mapping every nonzero outcome to 1; local signal failures use 128 plus the
signal number. A transport-uncertain child status is not proof the remote command
failed to execute. Runbook child codes 125 and 255 are conservatively treated as
uncertain client/transport failures, even if the application could have returned
that number; the code is preserved and the mutation marker remains.

Logs return a snapshot bounded to 500 lines and 64 KiB, not a follow stream.
History defaults to 25 operations (`--limit` accepts 1–100); it is local evidence,
not remote health. Prune requires `--yes` without prompting, checks exact ownership,
and preflights ownership before removing owned containers, fully owned secrets,
and the configured owned route. It retains unlabelled secrets, images, volumes,
and data. Partial cleanup is an error, not a successful wipe.

Preserve the existing Git-aware local deployment snapshot policy during the
cutover: evaluate, build, and resolve secret references from one prepared source.
Do not silently change dirty-checkout behavior while removing transport code.

## Runbook: first slice

A runbook is a target's named, described operational commands declared in Nix.
Schema `v0.5`, emitted by `nixploy.lib.makeConfig`, supports the following target
fragment inside that configuration. Targets need no authority profile; obsolete
control-plane configuration is rejected by the CLI. See the complete
[flake example](README.md#configure-an-application).

```nix
targets.production.runbook = {
  migrate = {
    description = "Run database migrations";
    command = [ "/app/bin/my-app" "migrate" ];
  };

  console = {
    description = "Open the application console";
    command = [ "/app/bin/my-app" "remote" ];
    interactive = true;
  };
};
```

`nixploy runbook -t production` lists available names and descriptions without
executing them. `nixploy run -t production NAME` evaluates the selected target's
local flake and executes the named argv inside its existing running container.
The command definition comes from the operator's checkout; the executable and
application environment come from the running container. No new image is built
or deployed. Report the selected container and deployed revision when available.

Execution requirements:

- Validate names (`[a-z0-9][a-z0-9_-]{0,62}`), non-empty executable argv,
  nonblank descriptions, and boolean `interactive`; its default is false.
- Verify complete Nixploy resource ownership and running state. Execute against
  the inspected container ID, never a name that could resolve to a replacement.
- For web applications, use the owned Caddy route to identify the active slot.
  A missing, foreign, or ambiguous active application fails before exec.
- Pass argv directly to Podman without implicit shell interpretation. No arbitrary
  command strings or additional user-supplied arguments in the initial slice.
- Use the container's existing environment, secrets, user, and mounts. Do not
  decrypt or reinstall secrets to run a command.
- Stream non-interactive stdout and stderr separately and propagate the exact
  child exit status, including nonzero and transport-uncertain outcomes.
  Keep command output out of retained deployment history; it may contain secrets.
- Allocate a terminal only for an explicitly interactive command with attached
  stdin and stdout terminals. Enable stdin only for interactive execution; streams may
  merge. Reject interactive execution in a non-terminal environment clearly.
- Never automatically retry a command after an uncertain transport failure:
  migrations and other operational commands may have side effects.
- Interruption must report uncertainty honestly; killing the local client does
  not prove that an already-started remote command stopped.
- Hold the shared remote mutation guard across selection and execution so another
  cooperating deploy/prune/run cannot replace the selected slot during execution.
  A known nonzero command exit releases the guard; uncertainty retains it without
  replacing the child's exit code with a generic failure.

Pre-start commands are automatic deployment steps. Runbook commands are explicit
operator actions; neither requires a general workflow engine. One-off containers,
scheduling, command chaining, and parameterized tasks are deferred until a real
use case justifies them.

## Architecture and safety

```text
CLI -> Application operations -> Git / Nix / SSH / Podman / SOPS / Caddy
                 |
                 +------------> local state where operationally necessary
```

OCaml remains the implementation language. Preserve the working deployment
engine rather than starting another rewrite. The original user-facing C# CLI
under `legacy/` is compatibility evidence, not the architectural template.

- Keep CLI parsing and rendering separate from deployment/runbook orchestration.
- Use focused modules with explicit `.mli` interfaces, validated invariant-bearing
  types, pure deployment decisions, and Async at effect boundaries.
- Parameterize real effects only where tests need it. A CLI-only product does not
  need abstractions for hypothetical future frontends.
- Preserve exact resource ownership, scoped cleanup, strict SSH host-key checking,
  secret-safe command construction, and bounded health/compensation operations.
- Use `Deployment_request.t` to validate one source/target selection, claim source
  preparation once, and bind execution to its history operation. It conveys no
  service admission authority and requires no registration.
- Preserve protection against overlapping mutations and interrupted deployments
  through the remote mutation guard described below. Local locks alone do not
  coordinate different laptops or CI runners.
- Keep local SQLite state only where it provides useful history or crash evidence.
  Local history is not authority over the remote server and is not proof of health.
- Do not remove or rename remote resources, delete state databases, or stop live
  services as a side effect of source cleanup. Existing service installations need
  explicit operator migration instructions before CLI cutover.

The module-design rules are in
[.agents/skills/ocaml-application-design/SKILL.md](.agents/skills/ocaml-application-design/SKILL.md).

### Mutation coordination

`Mutation_guard` acquires an atomic directory under `.nixploy-mutations/` in the
remote SSH login directory and syncs the evidence before invoking a mutation.
Remote `mkdir`, `sync`, and `rmdir` are required; no helper daemon or expiring lease
is involved. Coordination covers independent clients using the **same SSH account
and login directory**, scoped by project/target across repository and migration
identities. It does not coordinate separate remote accounts or non-cooperating
tools. Resource mutation still requires complete repository/project/target
ownership checks; the guard's broader scope is not ownership authorization.

Deploy, prune, and run all use this guard. Any callback error conservatively
retains the marker, even if the error may have preceded remote application changes.
Cancellation, lost clients, and transport uncertainty also retain evidence. There
is no age-based expiry, forced acquisition, or automatic replay. A known completed
outcome clears it; failure to confirm release must also be investigated.

When blocked, use the marker path reported in the diagnostic. Ensure no cooperating
client is still running; inspect the target's containers, route, secrets, and any
possibly still-running runbook command, and reconcile remote effects. Only then
may an operator manually remove that specific empty marker directory (using
`rmdir`, not broad recursive deletion) under the same SSH account/login directory.
Do not delete the entire guard directory or local history to bypass a failure.
Killing a local CLI or observing an old timestamp does not prove the remote work
stopped. A retry of a side-effecting runbook command is a new explicit operator
decision, never automatic recovery.

### Existing resources and secrets

Preserve identities, labels, running containers, routes, data, and old state during
cutover. New secrets carry ownership labels. Old unlabelled secrets are retained;
deployment does not overwrite or adopt them by name. Partially labelled or
contradictory metadata fails ownership verification. Prune removes fully owned
secrets only after ownership preflight and retains unlabelled secrets with a warning.
Any legacy secret replacement requires explicit provenance and consumer checks;
follow [MIGRATION.md](MIGRATION.md#legacy-podman-secrets).

## Delivery and validation

Use small end-to-end slices with an operator-visible acceptance criterion. For
each slice, exercise the packaged CLI as well as pure and process-boundary tests.
Assert argv, ownership failures, interruption, exit status, and compensation.

```bash
nix develop . -c dune runtest --root ocaml
nix develop . -c ./nix/test-mix-expo-source.sh
nix build .#nixploy
nix build .#checks.x86_64-linux.config-contract
nix build .#checks.x86_64-linux.cli-package-contract
nix build .#checks.x86_64-linux.cli-vm-smoke
```

These commands describe acceptance tooling, not a claim that the final integrated
build or VM check has passed. Retain deployment safety tests, including independent
clients, crashes, conservative error blocking, recovery, terminal behavior, exact
exit propagation, and no replay. A real remote deployment or runbook smoke test
requires a designated test target; never use a production application implicitly.

Commit and push validated task-owned changes according to
[.agents/skills/commit-and-push/SKILL.md](.agents/skills/commit-and-push/SKILL.md).
