# nixploy

nixploy is a small deployment CLI for shipping Nix-built OCI/Docker images to servers running Podman.

The goal is to keep deployment configuration next to your app in `flake.nix`, so the same image can be deployed to multiple targets such as dev, staging, and production. nixploy builds the configured flake image output, loads it into remote Podman over SSH, starts the container, and can optionally manage Caddy blue/green HTTP routing.

The active implementation is OCaml. Its application API is being made the single source of deployment behavior for both the CLI and Bonsai web UI, with the original user-facing C# CLI as the capability-parity reference. See [`DEVELOPMENT.md`](DEVELOPMENT.md) for the product boundary, OCaml module-design rules, parity definition, migration order, and legacy-code policy.

## What it does

- evaluates `.#nixploy` from the current flake
- builds a configured image output, for example `.#docker`
- creates/reuses a Podman SSH connection to the target server
- loads the image into remote Podman
- installs SOPS dotenv secrets as Podman secrets
- runs optional pre-start commands, such as migrations
- starts the long-running application container
- optionally switches a Caddy route after a health check
- scopes remote resources by project and target to avoid name conflicts

## Requirements

Local machine:

- Nix
- nixploy CLI
- Podman client
- SSH access to the target server
- `ssh-agent` with your deploy key loaded when using passphrase-protected keys
- `sops`, if using secrets

Target server:

- Podman service reachable over SSH
- Caddy with the admin API enabled, if using `web` deployments

## Flake configuration

Add nixploy as an input and expose a `nixploy` output:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixploy.url = "github:JonasThowsen/nixploy";
  };

  outputs = { self, nixpkgs, nixploy, ... }: {
    nixploy = nixploy.lib.makeConfig {
      project = "my-app";

      targets.production = {
        image = "docker"; # builds .#docker
        ip = "203.0.113.10";
        user = "root";
        port = 22;
        identityFile = "~/.ssh/id_ed25519";

        run = {
          network = "host";
          environment = {
            ASPNETCORE_URLS = "http://0.0.0.0:{port}";
          };
          preStart = [
            [ "/app/bin/migrate" ]
          ];
        };

        web = {
          domain = "app.example.com";
          healthPath = "/health";
          slots = {
            blue = 8080;
            green = 8081;
          };
        };

        secrets = {
          app = ./secrets/production.env;
        };
      };
    };
  };
}
```

The `project` name is required. nixploy combines it with a stable project id and target name when creating containers, secrets, Caddy route IDs, and local Podman connection names.

When `identityFile` points at a passphrase-protected key, load it into `ssh-agent` before deploying:

```bash
ssh-add ~/.ssh/id_ed25519
```

nixploy intentionally lets Podman connections use SSH/ssh-agent instead of storing the identity file in the Podman connection. This avoids passphrase prompts breaking later commands that need stdin, such as secret creation.

Example resource identity:

```text
nixploy-my-app-5d46b2643e-production
```

Containers also receive labels with the project, target, git commit, and deployment timestamp for debugging.

## Deploy

From the app flake directory:

```bash
nixploy deploy --target production
# or
nixploy deploy -t production
```

For a `web` target, nixploy uses blue/green deployment:

1. detects the active Caddy upstream port
2. starts the inactive slot container
3. health-checks it
4. switches Caddy to the new slot
5. stops the old slot

For a target without `web`, nixploy runs declared pre-start commands and then
replaces the single positively owned application container. Non-web deployment
does not contact Caddy.

## Prune

Remove the resources owned by one configured target:

```bash
nixploy prune --target production
# or, from another flake directory
nixploy prune -t production -C /srv/my-app
```

Prune resolves the same canonical or adopted legacy resource identity as deploy.
It checks ownership before removing the exact single, blue, and green container
names, removes only secrets prefixed by that resource key, and deletes the exact
Caddy route for web targets. Targets without `web` never contact Caddy. A name
collision with missing or contradictory ownership labels fails closed.

## Secrets

Secrets are local SOPS-encrypted dotenv files. At deploy time nixploy decrypts them locally, creates remote Podman secrets, and exposes each variable as an environment secret in the container.

Example dotenv after decryption:

```dotenv
DATABASE_URL=postgres://example
API_KEY=secret
```

Secret names must be unique across all configured secret files for a target.

## Useful commands

Evaluate the normalized config:

```bash
nix eval .#nixploy --json | jq
```

Build the image manually:

```bash
nix build .#docker -o result-nixploy-image
```

Run tests for the current OCaml CLI and control plane:

```bash
nix develop . -c dune runtest --root ocaml
```

## OCaml control plane

The default `nixploy` CLI and the Bonsai browser control plane are implemented in
OCaml and share the SQLite-backed tracked deployment path. See
[`ocaml/README.md`](ocaml/README.md) for implementation details,
[`ROADMAP.md`](ROADMAP.md) for the deliberately narrow product backlog, and
[`UI_DIRECTION.md`](UI_DIRECTION.md) for the responsive operator-interface
requirements.

Build and test the packaged implementation through Nix:

```bash
nix build .#nixploy
nix develop . -c dune runtest --root ocaml
```

## Legacy Phoenix implementation

The Phoenix, C#, and MoonBit implementations are legacy. They remain temporarily
because the existing NixOS service and Phoenix remote protocol still reference
them; they are not sources of future product scope. After the OCaml application
API and NixOS service cut over, they will move under `legacy/` and leave the
active root package graph. The development notes below apply only to that
transitional implementation.

Enter the reproducible development environment and initialize Phoenix:

```bash
nix develop
mix setup
```

`.sops.yaml` uses the same age recipient as jomat. `secrets/dev.env` is the
encrypted development environment, including the operator login, database URL,
Phoenix secrets, runtime role, host, and port. The small Justfile mirrors jomat:

```bash
just dev
just dev-iex
```

Both recipes decrypt the file directly into the server process environment
without writing a plaintext dotenv file. Edit it with
`sops secrets/dev.env`. Development seeds read the same encrypted operator
credentials, so resetting the database recreates the account before the server
starts:

```bash
mix ecto.reset
just dev
```

`mix setup` also runs the seeds on a fresh checkout. The checked-in values
target local PostgreSQL at `127.0.0.1` with the
credentials `postgres:postgres` and publish the development endpoint as
<https://dev-nixploy.tailb61fd1.ts.net/login>. Development uses password mode so
localhost remains usable. Phoenix stays bound to `127.0.0.1:4000`; the
Tailscale HTTPS proxy provides remote access, LiveView origin checks, and secure
session cookies.

The intended production deployment is the private `svc:nixploy` Tailscale
Service at <https://nixploy.tailb61fd1.ts.net>. Packaged NixOS services default
to Tailscale identity authentication: Serve injects a trusted
`Tailscale-User-Login`, nixploy matches it to a provisioned operator, and no
second password form is shown. Direct or unprovisioned identities receive HTTP
403. See [`TAILSCALE_AUTH_TRACER.md`](TAILSCALE_AUTH_TRACER.md) for the acceptance
criterion and trust boundary.

The same OTP application supports separate runtime roles:

```bash
NIXPLOY_ROLE=web mix phx.server
NIXPLOY_ROLE=worker mix run --no-halt
NIXPLOY_ROLE=all mix phx.server
```

`all` is the default for a simple development or single-node installation. The
worker role starts the PostgreSQL repository, Oban, and shared coordination
processes without starting the Phoenix endpoint. The web role starts the
endpoint with Oban in enqueue-only mode.

Committed releases can be delivered independently of deployment confirmation
through the bounded CI endpoint `POST /api/releases`. It accepts
`application/x-nix-nar`, authenticates a web-only bearer credential, restores at
most 32 MiB through fixed `nix-store --restore` argv in a private workspace,
recomputes its content-addressed identity with fixed `nix store add` argv, and
verifies the exact store path, NAR hash, allowlisted repository/project/target, and full Git object
ID before staging. Registration persists actor and provenance but never creates
a deployment job; the operator still reviews and confirms under `/releases`.

The Tailscale dashboard provides a local-host discovery tracer alongside the
scoped deployment-engine MVP. See [`LOCAL_HOST_TRACER.md`](LOCAL_HOST_TRACER.md)
for its acceptance criterion and [`MVP.md`](MVP.md) for release deployment,
security properties, and explicit limitations.

- authenticate a provisioned operator through the private Tailscale Service before exposing control-plane actions
- discover managed and unmanaged containers directly from the local Podman user
- show repository and revision identity from nixploy and OCI labels
- inspect a selected container's local runtime metadata and ephemeral recent logs with explicit time, line, and byte bounds
- probe a positively identified managed workload through bounded loopback `/health` and `/ready` observations derived from allowlisted runtime port metadata
- surface bounded Podman and health failures and allow an operator refresh without crashing the LiveView
- retain existing registered services and immutable deployment history without presenting manual onboarding forms
- enqueue an immutable, audited Oban deployment for retained services
- validate the committed flake target against the registered service before mutation
- stream bounded output and persisted deployment stages to the browser
- serialize target mutation with a renewable PostgreSQL lease
- request bounded process-group cancellation or redeploy an exact historical revision
- refresh persisted Podman, Caddy, slot, revision, and health observations through a worker
- fetch a bounded 200-entry active-container log snapshot through a worker
- independently verify the deployed commit, container, ingress, and health before success
- run web and worker processes independently through PostgreSQL notifications

The next no-GitHub replacement path is documented in
[`NATIVE_LOCAL_DEPLOYMENT_TRACER.md`](NATIVE_LOCAL_DEPLOYMENT_TRACER.md), including
the immutable Nix store input boundary and the safety conditions learned from
production rootless workloads.

The first real deployment tracer checks out the requested Git ref, records the
resolved commit, and delegates the checked-out repository to the existing
`nixploy deploy` CLI. This preserves the proven Nix, SSH, Podman, Caddy, and SOPS
behavior while the durable Elixir orchestration path is validated. During this
tracer the checked-out repository's `.#nixploy` output remains the deployment
configuration source, and the target name registered in the control plane must
match its flake target name. Repositories whose flake is not at the Git root can
set a relative flake subdirectory when registered.

Deployments are serialized per target with renewable PostgreSQL leases in
addition to the single-worker MVP queue. Workers must have Git, Nix, Bash,
`setsid`, OpenSSH, curl, Podman, SOPS, and the existing `nixploy` executable on `PATH`.
Set `NIXPLOY_LEGACY_EXECUTABLE` to an absolute executable path when it is
installed elsewhere. This compatibility adapter is temporary; native Elixir execution
adapters will replace it one end-to-end slice at a time. While the compatibility
command runs, detailed output is retained as one bounded 64 KiB tail while
structured progress remains in PostgreSQL. The coarse control-plane stage stays
`building` until the compatibility command completes.

Run both implementations' test suites while behavior is being ported:

```bash
mix test
dotnet test tests/Nixploy.Tests/Nixploy.Tests.csproj
```
