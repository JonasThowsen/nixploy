# nixploy

A daemonless CLI for deploying Nix-defined applications to remote Podman servers
over SSH, with SOPS secrets and optional Caddy blue/green routing.

Run it from an application's repository on your laptop or CI runner. There is no
Nixploy service, web UI, RPC endpoint, or application registry to install. The
remote server must already provide Podman and, for web applications, Caddy.
Server provisioning is outside the CLI's scope.

### Server requirements for surviving a reboot

nixploy starts application containers with `--restart=always`, but Podman only
restarts them at boot when `podman-restart.service` is enabled for the SSH account,
and a rootless account also needs lingering. Web routes are written through the
Caddy admin API, which Caddy forgets on restart unless it resumes its autosaved
configuration. A `caddy reload` from a Caddyfile replaces them even then, so
redeploy web targets after changing the server's Caddy configuration. On NixOS,
for a rootless `nixploy` account:

```nix
users.users.nixploy.linger = true;
systemd.user.services.podman-restart.wantedBy = [ "default.target" ];
# Rootful Podman instead: systemd.services.podman-restart.wantedBy = [ "multi-user.target" ];
services.caddy.resume = true; # web targets only
```

`deploy` and `status` check these settings read-only and warn when a target
would not come back after a reboot. Containers deployed before the restart policy was
introduced gain it on their next deployment.

The CLI-only implementation and isolated VM acceptance are complete; results are
recorded in [ROADMAP.md](ROADMAP.md). Existing service installations should follow
[MIGRATION.md](MIGRATION.md) before using the new CLI.

## Configure an application

For an existing flake that builds an image at `.#docker`, add the Nixploy input
and merge this output into its outputs function. `makeConfig` emits schema
`v0.5`; targets need no production/nonProduction authority profile.

```nix
{
  inputs.nixploy.url = "github:JonasThowsen/nixploy";

  outputs = { nixploy, ... }: {
    nixploy = nixploy.lib.makeConfig {
      project = "my-app";
      targets.production = {
        image = "docker";
        ip = "203.0.113.10";
        user = "deploy";
        run.network = "host";
        run.environment.PORT = "{port}";
        web = {
          domain = "app.example.com";
          healthPath = "/health";
          slots.blue = 8080;
          slots.green = 8081;
        };
        runbook = {
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
      };
    };
  };
}
```

The image output and application executables are supplied by your application,
not this example. Omit `web` for a non-web container and configure its runtime
environment as needed. Optional target fields include `secrets`, `run.preStart`,
and `run.readOnlyBinds`; see [nix/target.nix](nix/target.nix).

## Operate a target

```sh
nixploy deploy --target production --dry-run   # build and check, change nothing
nixploy deploy --target production
nixploy status --target production --json
nixploy logs --target production
nixploy history --target production --limit 25
nixploy runbook --target production
nixploy run --target production migrate
nixploy run --target production console

# Preview, then remove what the live deployment no longer uses: unserved
# containers, unmounted owned secrets, and owned images beyond the newest two.
nixploy prune --target production --stale --dry-run
nixploy prune --target production --stale --yes

# Take a target offline (route removed, containers stopped, restart disabled),
# then remove its containers, secrets, and images. Prune refuses a live target.
nixploy stop --target production
nixploy prune --target production --yes

# Everything nixploy owns on the target's host, including renamed or deleted
# targets and other projects; then remove one leftover by its resource key.
nixploy resources --target production
nixploy stop --target production --orphan RESOURCE_KEY
nixploy prune --target production --orphan RESOURCE_KEY --dry-run

# A failed or interrupted operation kept the mutation marker: review and remove it.
nixploy unlock --target production
nixploy unlock --target production --yes
```

Every command requires `--target` (`-t`). Use `--directory` (`-C`) to select a
different application checkout. Deploy, status, logs, history, prune, resources,
and runbook listing support `--json`; `run` streams the command's output instead. Diagnostics
and deployment progress go to stderr. With `--json`, a failure also prints
`{"error":{"code":"NIXPLOY_...","message":"..."}}` on stdout, so scripts and agents
can branch on the code. Logs are a bounded snapshot, not a follow
stream. History is local deployment evidence, not remote health.

`status` replaces logging in to run `podman ps` on the server. It shows each owned
container's role, state, uptime, restarts, CPU and memory, plus the Caddy route,
owned secrets, host-wide Podman storage and free disk, whether a mutation marker
is held, and reboot readiness, followed by a list of issues that need attention.

`deploy --dry-run` does everything a deploy does locally (snapshot, evaluation,
image build, secret decryption) and then checks the host read-only: SSH, Podman,
read-only bind sources, secret ownership, the Caddy route and the candidate slot
and whether its port is already taken, the mutation marker, and reboot readiness.
It prints the plan (slot, containers replaced, secrets created or replaced,
pre-start commands) and exits 1 if it finds a blocker. It takes no guard and
records no history.

Deploy evaluates configuration, builds, and resolves secrets from one Git-aware
snapshot: committed files, tracked modifications, and intent-to-add files are
included; ignored files are excluded; ordinary non-ignored untracked files are
rejected. Load passphrase-protected SSH keys into `ssh-agent` and establish trusted
host keys before connecting. Nix, SSH, Podman, and SOPS tooling are included in the
package's runtime path; SSH and SOPS credentials remain the operator's responsibility.
Never put private keys or plaintext secrets in flake values or the Nix store.

### Agents and sandboxes

nixploy behaves the same in a terminal and in a sandboxed coding agent:

- Local Podman client state (connection records and its runtime directory) lives
  in a private per-process directory under `$TMPDIR`, so a read-only `~/.config`
  or `/run/user/UID` does not matter and your own `podman system connection list`
  is left alone.
- When `SSH_AUTH_SOCK` is unset or unusable, nixploy adopts the standard per-user
  agent socket (`/run/user/UID/ssh-agent`, keyring, gcr or gpg-agent) and says so
  on stderr. Podman's SSH client cannot decrypt a passphrase-protected key, so a
  reachable agent is the supported way to use one.
- SSH failures are `NIXPLOY_SSH_FAILED` errors that name the destination, the
  last SSH messages, and the likely fix: no usable key (and which agent and
  identity file this process can see), an untrusted host key, or an unreachable
  network.
- `status` and `logs` open no local history. `deploy`, `stop`, `prune` and
  `history` need a writable history database: allow writes to
  `~/.local/state/nixploy`, or set `NIXPLOY_STATE_DB`.

## Runbook behavior

`runbook` lists local names and descriptions without SSH or execution. `run`
evaluates the local command definition and executes literal argv once inside the
positively owned running container, selected by ID. For web targets, the owned
Caddy route determines the active slot. The selected container and available
deployed revision are reported on stderr.

There is no build, deployment, secret decryption, or one-off container. The
command uses the running container's existing environment, secrets, user, and
mounts. Non-interactive stdout and stderr stream separately and the child exit
code is propagated exactly, including nonzero and transport-uncertain outcomes.
Interactive commands require attached stdin and stdout terminals and explicitly
enable stdin and terminal allocation; terminal streams may merge. Commands accept no extra
CLI arguments and are never automatically replayed after a failure. Child codes
125 and 255 are conservatively treated as uncertain client/transport outcomes:
the code is preserved, but the mutation marker remains until `nixploy unlock`.

## Mutation safety and recovery

Deploy, prune, and run share a durable remote mutation guard. Independent clients
using the **same SSH account and login directory** coordinate through an atomic
directory under `.nixploy-mutations/`. This is uncertainty evidence, not an
expiring lease; different SSH accounts are not coordinated by this mechanism.

A deploy that fails while the remote state is known releases the marker, so a
corrected deploy can run right away. That covers failures before any application
container is touched (evaluation, build, image load, secrets), a pre-start command
with a known nonzero exit, and a failed candidate that was removed with the route
restored and read back. The failure reports the candidate's state, exit code and
last log lines (redacted), or the pre-start command's last output. Any other
error after guard acquisition leaves the marker and blocks further mutations.
Disconnects, cancellation, and elapsed time do not permit automatic takeover.

Recover without SSH:

```sh
nixploy unlock --target production        # marker, holder, current status; exits 2
nixploy unlock --target production --yes  # remove exactly that marker
```

`unlock` shows which command, host and process took the marker and when, followed
by the target's full status and issues. With `--yes` it removes only that
target's marker, and refuses while the recorded holder is still running on this
machine. Check that no other machine or agent is still acting and that the state
is what you expect, then unlock and redeploy to fix any remaining issues. See
[DEVELOPMENT.md](DEVELOPMENT.md#mutation-coordination) and
[MIGRATION.md](MIGRATION.md). Never blindly retry a migration.

Prune requires `--yes` (or `--dry-run` to preview) and checks exact ownership
before removal. It never removes a Caddy route or a running application: take a
target offline with `stop` first, which removes its route and stops its containers
with restart disabled; `deploy` brings a stopped target back. Without `--stale`,
prune removes a stopped target's owned containers, fully owned secrets, and owned
images. With `--stale` it keeps the live
deployment and removes only what it no longer uses; `--keep` sets how many recent
owned images survive. Deploy tags images into `localhost/nixploy/<resource key>`,
so images loaded before that change are not owned and are never pruned. Volumes
and data are always retained.

`resources` lists every nixploy resource on the target's host and marks those whose
target this flake no longer declares. `stop --orphan RESOURCE_KEY` and then
`prune --orphan RESOURCE_KEY` take one such leftover offline and remove it, each
re-verifying its ownership labels under that target's own mutation guard. They
refuse anything the flake still declares; use plain `stop` and `prune` for those. Old unlabelled secrets are retained and are **not automatically
overwritten or adopted**. A same-name legacy secret requires explicit operator
migration, not prefix-based deletion; see [legacy secret migration](MIGRATION.md#legacy-podman-secrets).

## Development

OCaml is the active implementation. Historical code under
[legacy/](legacy/README.md) is compatibility evidence, not an active dependency.

```sh
nix develop . -c dune runtest --root ocaml
nix build .#nixploy
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for the product contract,
[ocaml/README.md](ocaml/README.md) for implementation navigation, and
[AGENTS.md](AGENTS.md) for repository agent instructions.
