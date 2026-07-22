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

1. Sign in with a provisioned operator.
2. Register or correct a repository, target, and service.
3. Queue a branch, tag, or commit.
4. Observe the request resolve once to an immutable commit.
5. Confirm that a mismatched flake target is rejected before deployment.
6. Follow bounded deployment output and structured stages.
7. Confirm success only after an independent SSH/Caddy/health observation sees the expected commit.
8. Refresh status and fetch bounded active-container logs.
9. Cancel active work or redeploy an exact historical revision.
10. Review the append-only operator audit table.
11. Restart the process and confirm all history and observations remain.

## Development quick start

```bash
nix develop
mix setup
NIXPLOY_OPERATOR_PASSWORD='use a long password' \
  mix nixploy.operator operator@example.com
mix phx.server
```

Open <http://localhost:4000>. Liveness and database readiness are available at `/health` and `/ready` without authentication.

## Reproducible release

```bash
nix build .#control-plane
```

The release includes the compatibility CLI and the worker runtime commands in its PATH. Configure it with an environment file readable only by the service user:

```dotenv
DATABASE_URL=ecto://nixploy:password@127.0.0.1/nixploy
SECRET_KEY_BASE=replace-with-mix-phx-gen-secret-output
RELEASE_COOKIE=replace-with-an-independent-random-value
PHX_HOST=nixploy.example.com
NIXPLOY_ROLE=all
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

Automated validation includes 80 Elixir tests, 29 C# tests, repeated execution-runner stress tests, `nix flake check --no-build`, a successful `.#control-plane` build, release migrations, readiness checks, adapter path verification, and an authenticated packaged-dashboard smoke test.

## Explicitly after MVP

Inline `TODO(tracer)` markers retain the next safe expansion points. Major post-MVP work includes native Elixir mutation adapters, remote fencing enforcement, split web/worker credential isolation, role-based authorization, revocable multi-device sessions, artifact-store log history, scheduled health checks, one-off tasks/exec, and broader CLI parity.
