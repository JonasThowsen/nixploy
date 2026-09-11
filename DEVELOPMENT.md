# nixploy development direction

## Product contract

nixploy is a daemonless CLI for deploying and operating applications defined in
Nix. Run it from an application's repository on a laptop or CI runner against an
already-provisioned remote server. The project flake is the configuration source;
SSH is the transport; Podman runs the application; SOPS supplies secrets; Caddy
optionally routes application HTTP traffic.

This contract supersedes the control-plane, browser, and Production V1 plans.
It describes the agreed destination, not a claim that the existing implementation
has already been stripped down. Track that work in [ROADMAP.md](ROADMAP.md).

### Keep

- Nix image evaluation, builds, and remote image loading.
- Explicit deployment targets and stable repository/project/target ownership.
- SOPS dotenv secrets, fixed pre-start argv, and existing runtime configuration.
- Non-web container replacement and Caddy blue/green web deployments.
- Health checks, bounded failure recovery, and honest reporting of uncertainty.
- Scoped status, logs, cleanup, and small local history where useful.
- Named runbook commands executed inside the running application container.

### Remove

- The Nixploy web UI, HTTP server, browser authentication, and RPC transport.
- The Nixploy service and managed-application registration requirement.
- Managed checkouts, custody records, authority aliases, and preview receipts
  whose purpose was centralized deployment admission.
- Dashboard telemetry, background observers, queues, schedulers, and plugins.

There is no Nixploy daemon on either the operator machine or the target. The
target's existing Podman service and optional Caddy service are still required.
Server provisioning is outside the deployment CLI's scope.

## CLI contract

The intended command surface is:

```console
nixploy deploy --target production
nixploy status --target production
nixploy logs --target production
nixploy history --target production
nixploy prune --target production
nixploy runbook --target production
nixploy run --target production migrate
```

Every command takes an explicit target from the project flake. Direct execution
is the only deployment mode, not an override or a less-trusted fallback. A normal
deployment requires no root-owned application registry or Nixploy service.

Human output should be concise and actionable. Structured inspection and
deployment results should be available through `--json`, with progress on stderr
and documented exit codes. Automation must not encounter unexpected prompts or
automatic terminal allocation. Destructive cleanup needs explicit scope and
confirmation; do not expose an unsafe cleanup path merely to complete this list.

Preserve the existing Git-aware local deployment snapshot policy during the
cutover: evaluate, build, and resolve secret references from one prepared source.
Do not silently change dirty-checkout behavior while removing transport code.

## Runbook: first slice

A runbook is a target's named, described operational commands declared in Nix.
The initial configuration shape is planned, not implemented:

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

- Validate names, non-empty executable argv, descriptions, and the boolean
  `interactive` field; its default is false.
- Verify complete Nixploy resource ownership and running state. Execute against
  the inspected container ID, never a name that could resolve to a replacement.
- For web applications, use the owned Caddy route to identify the active slot.
  A missing, foreign, or ambiguous active application fails before exec.
- Pass argv directly to Podman without implicit shell interpretation. No arbitrary
  command strings or additional user-supplied arguments in the initial slice.
- Use the container's existing environment, secrets, user, and mounts. Do not
  decrypt or reinstall secrets to run a command.
- Stream stdout and stderr separately and propagate the command exit status.
  Keep command output out of retained deployment history; it may contain secrets.
- Allocate a terminal only for an explicitly interactive command with an attached
  terminal. Reject interactive execution in a non-terminal environment clearly.
- Never automatically retry a command after an uncertain transport failure:
  migrations and other operational commands may have side effects.
- Interruption must report uncertainty honestly; killing the local client does
  not prove that an already-started remote command stopped.
- Coordinate runbook execution with deployment sufficiently to prevent selecting
  an active slot while that slot is being replaced. The daemonless coordination
  mechanism must be tested before runbook mutation is enabled.

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
- Preserve protection against overlapping mutations and interrupted deployments.
  Replace necessary coordination with a daemonless mechanism; do not silently
  drop it alongside the old broker. Local locks alone do not coordinate different
  laptops or CI runners. Fail clearly on conflicts rather than inventing takeover.
- Keep local SQLite state only where it provides useful history or crash evidence.
  Local history is not authority over the remote server and is not proof of health.
- Do not remove or rename remote resources, delete state databases, or stop live
  services as a side effect of source cleanup. Existing service installations need
  explicit operator migration instructions before CLI cutover.

The module-design rules are in
[.agents/skills/ocaml-application-design/SKILL.md](.agents/skills/ocaml-application-design/SKILL.md).

## Delivery and validation

Use small end-to-end slices with an operator-visible acceptance criterion. For
each slice, exercise the packaged CLI as well as pure and process-boundary tests.
Assert argv, ownership failures, interruption, exit status, and compensation.

```bash
nix develop . -c dune runtest --root ocaml
nix develop . -c ./nix/test-mix-expo-source.sh
nix build .#nixploy
```

These checks describe the current repository tooling. Remove web-only tests and
dependencies with their implementation, while retaining deployment safety tests.
A real remote deployment or runbook smoke test requires a designated test target;
never use a production application implicitly.

Commit and push validated task-owned changes according to
[.agents/skills/commit-and-push/SKILL.md](.agents/skills/commit-and-push/SKILL.md).
