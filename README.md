# nixploy

nixploy is a small deployment CLI for shipping Nix-built OCI/Docker images to servers running Podman.

The goal is to keep deployment configuration next to your app in `flake.nix`, so the same image can be deployed to multiple targets such as dev, staging, and production. nixploy builds the configured flake image output, loads it into remote Podman over SSH, starts the container, and can optionally manage Caddy blue/green HTTP routing.

The active implementation is OCaml. Its application API is the single source of deployment behavior for both the CLI and Bonsai web UI, with the original user-facing C# CLI retained only as a capability-parity reference under [`legacy/`](legacy/README.md). See [`DEVELOPMENT.md`](DEVELOPMENT.md) for the product boundary, OCaml module-design rules, and delivery milestones.

## What it does

- evaluates `.#nixploy` from the current flake
- builds a configured image output, for example `.#docker`
- creates/reuses a Podman SSH connection to the target server
- loads the image into remote Podman
- installs SOPS dotenv secrets as Podman secrets
- runs optional pre-start commands, such as migrations
- mounts typed existing host paths read-only in pre-start and application containers
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
          readOnlyBinds = [
            {
              source = "/srv/my-app/reference-data";
              destination = "/app/reference-data";
            }
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

Local deployment uses Git-aware flake source semantics: committed files,
tracked modifications, and intent-to-add files are eligible, while ignored build
artifacts such as `deps/`, `_build/`, and `node_modules/` are excluded. Nixploy
rejects ordinary non-ignored untracked files rather than silently deploying
without them. Add an intentional new file to the index first (`git add -N --
PATH` is sufficient).

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

Prune resolves the same repository-bound resource identity as deploy. Under
that scope, a container counts as owned only when it carries the complete modern
`io.nixploy.managed=true`, project, target, and resource-key labels. Legacy
`nixploy.*` ownership labels are not accepted. Prune checks
ownership before removing the exact single, blue, and green container names,
removes only secrets prefixed by that resource key, and deletes the exact Caddy
route for web targets. Targets without `web` never contact Caddy. A name
collision with missing, partial, legacy-only, or contradictory ownership labels
fails closed.

## Secrets

Secrets are local SOPS-encrypted dotenv files. At deploy time nixploy decrypts them locally, creates remote Podman secrets, and exposes each variable as an environment secret in the container.

Example dotenv after decryption:

```dotenv
DATABASE_URL=postgres://example
API_KEY=secret
```

Secret names must be unique across all configured secret files for a target.

## Read-only bind mounts

Schema `v0.4` adds the typed `run.readOnlyBinds` list. Each entry contains only
`source` and `destination`; nixploy always renders it as the two shell-free
Podman arguments:

```text
--mount type=bind,source=/srv/my-app/reference-data,destination=/app/reference-data,ro=true
```

The same ordered bind arguments are applied to every pre-start container and
the long-running application container. Writable mode, raw Podman arguments,
and arbitrary mount options are intentionally unavailable.

Both values must be non-root absolute normalized Unix paths. Empty, relative,
trailing-slash, repeated-slash, dot, dot-dot, comma, and control-character paths
are rejected, as are unknown bind fields, identical source/destination pairs,
and duplicate destinations. Before building or running deployment containers,
nixploy checks each source on the remote host with the configured SSH identity.
A missing or inaccessible source fails the deployment; nixploy never creates
it. Paths are checked lexically and remote symlink resolution remains the
remote runtime's responsibility.

The OCaml parser continues to accept schemas `v0.2` and `v0.3` for deployments
without this field. Supplying `readOnlyBinds` under either older schema is an
error rather than a silently ignored mount requirement.

## Updating an older nixploy input

Existing project configuration for deploy, prune, web/non-web targets, runtime
environment, ports, pre-start commands, secrets, and read-only binds remains
source-compatible. Updating the input automatically evaluates that configuration
as schema `v0.4`; the package outputs remain `packages.default` and
`packages.nixploy`, and `nixployModules.default` remains available.

If the input URL already follows the default branch, update normally:

```bash
nix flake lock --update-input nixploy
nix eval .#nixploy --json | jq -e '.__schema == "v0.4"'
nix flake check
```

A URL pinned to a migration branch, such as
`github:JonasThowsen/nixploy/rewrite/control-plane`, stays on that branch when
only its lock is updated. Change it to `github:JonasThowsen/nixploy` first, then
run the commands above to move back to `main`.

Remove any `tasks` declaration before updating. Named operational tasks belonged
to a retired control-plane experiment and were never executed by the supported
CLI; schema `v0.4` rejects them instead of silently accepting dead configuration.
Older schema `v0.3` output containing the historical default `tasks = { }` is
accepted by the new CLI, but non-empty task declarations fail explicitly.

Project checks that intentionally pin `nixploy.lib.schema`, `config.__schema`, or
the exact `flake.lock` revision must update those assertions to `v0.4` and the
new lock revision. These assertions are expected coordination guards rather than
runtime compatibility contracts.

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
OCaml. Both deploy and scoped prune flow through the shared `Application` API;
deployments also share the SQLite-backed tracked deployment path. Resource
presence is stored separately: deploy success is present, completed prune is
absent, and prune in progress or failed is unknown, without deleting historical
deployment outcomes. See
[`ocaml/README.md`](ocaml/README.md) for implementation details,
[`PRODUCTION_LIFECYCLE_V1.md`](PRODUCTION_LIFECYCLE_V1.md) for the bounded V1
operator contract, [`ROADMAP.md`](ROADMAP.md) for delivery order and completed
receipts, and [`UI_DIRECTION.md`](UI_DIRECTION.md) for the responsive
operator-interface requirements.

Build and test the packaged implementation through Nix:

```bash
nix build .#nixploy
nix develop . -c dune runtest --root ocaml
```

## NixOS service

The default NixOS module runs the packaged OCaml `nixploy-web` executable as one
`nixploy.service`. It listens only on `127.0.0.1`, stores its SQLite database and
Podman connection configuration beneath `/var/lib/nixploy`, and uses one
long-lived `nixploy` Unix identity. A reverse proxy such as Tailscale Serve can
publish the loopback endpoint.

```nix
{
  imports = [ inputs.nixploy.nixosModules.default ];

  services.nixploy = {
    enable = true;
    port = 8080;

    authMode = "tailscale";
    operatorEmail = "operator@example.com";
    # Set only when the browser's public origin differs from the forwarded Host.
    allowedOrigin = "https://nixploy.example.com";

    applications.my-app = {
      project = "my-app";
      target = "production";
      repository = "/srv/nixploy/my-app";
      repositoryIdentity = "owner/my-app";
      subdirectory = ".";
    };

    sshIdentityFile = "/run/keys/nixploy-ssh";
    sshKnownHostsFile = "/run/keys/nixploy-known-hosts";
    sopsAgeKeyFile = "/run/keys/nixploy.age";
  };
}
```

`repository` must be an absolute existing local Git checkout readable by the
service user. The module passes only the fields accepted by OCaml
`Managed_application`: `project`, `target`, `repository`,
`repositoryIdentity`, and relative `subdirectory`. Credential options use
systemd credentials and set the actual OCaml SSH/SOPS environment names.
`readOnlyPaths` can expose additional Git credential-helper configuration while
Unix ownership and file modes remain the access boundary. `environmentFile` is
optional and is intended only for additional process environment. A generated
start wrapper reapplies module-owned authentication, origin, application, and
credential variables after systemd loads that file, so it cannot override those
security boundaries.

For a deliberately trusted local-only installation, set
`authMode = "unrestricted"`. Tailscale mode requires `operatorEmail`, but
loopback TCP alone is not a trusted-proxy boundary because direct local clients
can reach it. Production V1 requires direct requests in Tailscale mode to be
rejected: the proxy must strip caller-supplied identity, inject only verified
identity, and cross an authenticated or otherwise protected proxy-to-service
boundary inaccessible to direct local clients. A protected Unix socket or an
equivalent design can satisfy that requirement; the implementation choice is
intentionally not fixed here. The health endpoint is `GET /healthz`.

`services.nixploy-control-plane` is a rename alias for `services.nixploy` to
make the namespace transition explicit. It does not restore the removed
Phoenix roles, workers, PostgreSQL, Ecto migrations, release registration, or
backup options.

### Migration fence

Treat the service replacement as an engine cutover, not a rolling upgrade:

1. Stop and disable every old Phoenix web and worker process before starting
   `nixploy.service`. Never overlap old and OCaml deployment engines, including
   during rollback.
2. Preserve the existing long-lived `nixploy` Unix identity, repository
   checkouts, SSH host verification material, deploy keys, SOPS age identities,
   and access modes. Point the new module options at those same assets.
3. Start the OCaml service and verify `systemctl is-active nixploy`,
   `curl http://127.0.0.1:8080/healthz`, and the operator UI before enabling the
   public proxy.

The new SQLite history starts at `/var/lib/nixploy/state.sqlite3`. Historical
Phoenix/PostgreSQL deployment rows are not migrated. Existing remote Podman,
secret, and Caddy ownership identities are preserved by the OCaml application
engine rather than copied from PostgreSQL.

## Legacy archive

The retired Phoenix, C#, and MoonBit implementations and historical rewrite
notes are preserved under [`legacy/`](legacy/README.md) for reference only. The
root flake does not package, check, or depend on the archive. Its only package
outputs are `packages.nixploy` and `packages.default`, both containing the active
OCaml CLI and web service.
