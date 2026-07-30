# nixploy control-plane MVP

This branch contains the first deployable control-plane MVP. It is intentionally scoped to:

- one trusted operator network
- one combined `all` web/worker process
- one PostgreSQL database
- trusted Git repositories
- Caddy blue/green web targets
- worker-owned SSH credentials and strict `known_hosts`
- the existing C# CLI as a temporary Nix/Podman/Caddy mutation adapter

## What to evaluate

1. Open the private Tailscale Service and confirm its identity header matches a provisioned operator without a second password prompt.
2. Confirm the dashboard detects the local hostname, runtime user, and Podman installation without registering a target.
3. Confirm managed and unmanaged containers appear automatically and probe failures can be retried.
4. Confirm labeled workloads show project, repository, slot, and exact revision where available.
5. For retained legacy service records, queue a branch, tag, or commit.
6. Observe the request resolve once to an immutable commit.
7. Confirm that a mismatched flake target is rejected before deployment.
8. Follow bounded deployment output and structured stages.
9. Confirm success only after an independent SSH/Caddy/health observation sees the expected commit.
10. Refresh status, fetch logs, cancel active work, or redeploy an exact historical revision.
11. Review the append-only operator audit table and confirm history survives a restart.

## Development quick start

```bash
nix develop
mix ecto.reset
just dev
```

Development seeds provision the operator from `secrets/dev.env`, so a reset
recreates the configured account. (`mix setup` runs the same seeds on a fresh
checkout.) The small Justfile mirrors jomat: `just dev` and `just dev-iex`
decrypt `secrets/dev.env` directly into the server process environment. Edit
the encrypted dotenv file with `sops secrets/dev.env`.

Open <https://dev-nixploy.tailb61fd1.ts.net/login>. Development stays in
password mode and Phoenix remains bound to `127.0.0.1:4000` behind the Tailscale
HTTPS proxy. Liveness and database readiness are available at `/health` and
`/ready` without authentication.

The intended packaged production profile uses `NIXPLOY_AUTH_MODE=tailscale`
and the private `svc:nixploy` Tailscale Service. Serve's trusted
`Tailscale-User-Login` must match a provisioned operator; password login is
disabled in that profile.

## Reproducible release

```bash
nix build .#control-plane
```

The release includes the compatibility CLI and the worker runtime commands in
its PATH. For a NixOS service, materialize the required production values as an
environment file readable only by the service user (for example with sops-nix
or another host-side secret provisioner):

```dotenv
DATABASE_URL=ecto://nixploy:password@127.0.0.1/nixploy
SECRET_KEY_BASE=replace-with-mix-phx-gen-secret-output
RELEASE_COOKIE=replace-with-an-independent-random-value
PHX_HOST=nixploy.example.com
PHX_BIND_IP=127.0.0.1
NIXPLOY_ROLE=all
NIXPLOY_AUTH_MODE=tailscale
```

Migrate and provision the first operator:

```bash
set -a; . /run/keys/nixploy.env; set +a
result/bin/nixploy eval 'Nixploy.Release.migrate()'
result/bin/nixploy eval \
  'Nixploy.Release.provision_operator("operator@example.com", System.fetch_env!("NIXPLOY_OPERATOR_PASSWORD"))'
result/bin/nixploy start
```

A NixOS service is also available:

```nix
{
  inputs.nixploy.url = "github:JonasThowsen/nixploy/rewrite/control-plane";

  imports = [ inputs.nixploy.nixosModules.default ];

  services.nixploy-control-plane = {
    enable = true;
    role = "all";
    environmentFile = "/run/keys/nixploy.env";
  };
}
```

Place the worker user's SSH `known_hosts` and any required credential references under `/var/lib/nixploy`. Unknown host keys and interactive credential prompts fail closed.

## Safety properties in this MVP

- Deployment input records are snapshotted when queued.
- A Git ref is resolved once; retries fetch the stored commit.
- The evaluated `.#nixploy` target must match registered host, user, port, image, domain, and health path.
- PostgreSQL target leases prevent concurrent control-plane mutations and carry increasing fencing tokens.
- Cancellation sends TERM to the command process group, waits, escalates to KILL, and only then records cancellation.
- The compatibility CLI returns non-zero operational failures.
- Caddy state inspection fails closed and never falls back to replacing the complete Caddy configuration.
- Success requires an independently observed running container, matching commit label, and 2xx health response.
- Deployment output is retained as one bounded 64 KiB tail rather than unbounded event rows.
- Dashboard history, rendered events, status, and logs are bounded.
- Status/log request generations prevent stale workers overwriting newer requests.
- Login failures are generically reported, throttled, and audited without storing attempted email addresses.
- Production session cookies are encrypted, signed, HTTP-only, secure, and time-limited.

## Operational requirements

- Back up PostgreSQL before upgrades and restore it into the same or newer schema version.
- Run release migrations once before starting upgraded processes.
- Do not run the standalone CLI manually against a target while a control-plane deployment is active. The compatibility CLI cannot yet propagate the database fencing token to remote mutations.
- Keep the control plane behind HTTPS on a trusted administrative network.
- Treat registered repositories as trusted code; Nix evaluation and builds are not an untrusted-code sandbox.
- Keep SSH/SOPS keys out of PostgreSQL and the web process environment.

## Validation evidence

The MVP was validated against SSH target `nixploy-test` with fixture deployment `9ccef485-3937-461e-9900-f92b416e360b`:

- resolved and persisted commit `55ef9e674e5d353127313e32aa819d967b6a68a2`
- validated the normalized flake target and persisted its configuration digest
- switched Caddy to the blue container on `127.0.0.1:8080`
- independently observed the matching `55ef9e674e5d` container label and HTTP 200 health
- retained 46 compatibility-output lines in the bounded deployment output
- fetched a new generation-fenced 10-line log snapshot directly over strict SSH

The local-host tracer was additionally exercised against the real Podman CLI on
`netcup-dev`, where it observed the authenticated runtime user and a valid empty
inventory without SSH or registration records.

Automated validation includes 83 Elixir tests, 29 C# tests, repeated execution-runner stress tests, `nix flake check --no-build`, a successful `.#control-plane` build, release migrations, readiness checks, adapter path verification, and an authenticated packaged-dashboard smoke test.

## Explicitly after MVP

Inline `TODO(tracer)` markers retain the next safe expansion points. Local host
capabilities come before any GitHub integration: workload inspection and bounded
ephemeral logs are followed by one real local health/probe observation and then
a native no-GitHub deployment slice derived from a project flake. Major post-MVP
work also includes remote fencing enforcement, split web/worker credential
isolation, richer Tailscale role mapping, identity-only operator provisioning,
revocable sessions, artifact-store log history, scheduled health checks,
one-off tasks/exec, and broader CLI parity. GitHub App installation, repository
metadata, webhooks, and GitHub revision selection remain explicitly deferred.
