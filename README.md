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
OCaml. Both deploy and scoped prune flow through the shared `Application` API;
deployments also share the SQLite-backed tracked deployment path. Resource
presence is stored separately: deploy success is present, completed prune is
absent, and prune in progress or failed is unknown, without deleting historical
deployment outcomes. See
[`ocaml/README.md`](ocaml/README.md) for implementation details,
[`ROADMAP.md`](ROADMAP.md) for the deliberately narrow product backlog, and
[`UI_DIRECTION.md`](UI_DIRECTION.md) for the responsive operator-interface
requirements.

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
`authMode = "unrestricted"`. Tailscale mode requires `operatorEmail` and should
sit behind a proxy that removes untrusted client-supplied identity headers. The
health endpoint is `GET /healthz`.

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
