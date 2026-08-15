# nixploy

nixploy is a small deployment CLI for shipping Nix-built OCI/Docker images to servers running Podman.

The goal is to keep deployment configuration next to your app in `flake.nix`, so the same image can be deployed to multiple targets such as dev, staging, and production. nixploy builds the configured flake image output, loads it into remote Podman over SSH, starts the container, and can optionally manage Caddy blue/green HTTP routing.

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

For a non-web target, nixploy replaces the project-scoped container directly.

For a `web` target, nixploy uses blue/green deployment:

1. detects the active Caddy upstream port
2. starts the inactive slot container
3. health-checks it
4. switches Caddy to the new slot
5. stops the old slot

## Prune a target

Remove resources for the current project/target identity:

```bash
nixploy prune --target production
```

This removes:

- project-scoped containers
- project-scoped Podman secrets
- the project-scoped Caddy route, for web targets

It does not remove old legacy names or resources from other projects.

## Secrets

Secrets are local SOPS-encrypted dotenv files. At deploy time nixploy decrypts them locally, creates remote Podman secrets, and exposes each variable as an environment secret in the container. The members of the `secrets` object are intentionally arbitrary user-defined labels whose values must be file path strings; they are map keys, not extensible schema fields.

Example dotenv after decryption:

```dotenv
DATABASE_URL=postgres://example
API_KEY=secret
```

Secret names must be unique across all configured secret files for a target.

## Read-only bind mounts

Use `run.readOnlyBinds` to expose an existing directory or file from the remote
host to every pre-start and application container. Each bind is always rendered
as a read-only Podman bind mount; writable mode and arbitrary mount options are
not configurable.

Both paths must be non-root, absolute, lexically normalized Unix paths. The
source is a path on the remote deployment host, so nixploy validates its syntax
without requiring it to exist on the local machine. This lexical check rejects
empty, dot, and dot-dot segments, but does not resolve symlinks in either the
host source or container destination; symlink resolution is left to the remote
container runtime. Destinations must be unique.

## Useful commands

Evaluate the normalized config:

```bash
nix eval .#nixploy --json | jq
```

Build the image manually:

```bash
nix build .#docker -o result-nixploy-image
```

Run tests for nixploy itself:

```bash
dotnet test tests/Nixploy.Tests/Nixploy.Tests.csproj
```
