# nixploy

A pragmatic CLI for deploying Nix-defined applications to remote Podman servers
over SSH, with SOPS secrets and optional Caddy blue/green routing.

**The agreed direction is CLI-only and daemonless.** Run Nixploy from your laptop
or CI runner; there should be no Nixploy service or web UI to install or maintain.
The remote server is already provisioned with Podman and, for web apps, Caddy.

## Transition status

The repository is being simplified from an OCaml CLI/web control plane. The web
code, RPC transport, service packaging, and managed authority machinery still
exist today. This documentation change records the new direction; it does not
claim those components have already been removed.

The current CLI has a direct deployment path for explicitly declared unmanaged
`production` or `nonProduction` targets. It also exposes status and local history.
Prune remains disabled. The named runbook and uniform `--json` contract described
in the development plan are not implemented yet.

See [DEVELOPMENT.md](DEVELOPMENT.md) for the authoritative product and runbook
contract, and [ROADMAP.md](ROADMAP.md) for the implementation sequence.

## Core workflow

The application flake declares its image, target server, runtime configuration,
optional SOPS secret files, pre-start commands, and optional Caddy web routing.
Nixploy evaluates that configuration, builds the image, loads it into remote
Podman, and verifies the deployment.

For an existing flake that builds an image at `.#docker`, add the Nixploy input
and expose a configuration like this (current schema):

```nix
{
  inputs.nixploy.url = "github:JonasThowsen/nixploy";

  # Merge this output into the application's existing outputs function.
  outputs = { nixploy, ... }: {
    nixploy = nixploy.lib.makeConfig {
      project = "my-app";
      targets.production = {
        image = "docker";
        ip = "203.0.113.10";
        user = "deploy";
        production.coordinationScope = "my-app-production";
        run.network = "host";
        run.environment.PORT = "{port}";
        web = {
          domain = "app.example.com";
          healthPath = "/health";
          slots.blue = 8080;
          slots.green = 8081;
        };
      };
    };
  };
}
```

Omit `web` for an ordinary non-web container and configure its runtime environment
as needed. The current authority-profile requirement shown above is slated for
removal; it is not part of the intended minimal configuration.

Existing direct CLI commands:

```sh
nixploy deploy --target production
nixploy status --target production
nixploy history --target production
```

Deploy uses a Git-aware local snapshot: committed files, tracked modifications,
and intent-to-add files are included; ignored files are excluded; ordinary
non-ignored untracked files are rejected rather than silently omitted. Build and
secret references consume the same prepared source.

The caller needs Nix, SSH credentials and trusted host keys, the Podman client,
and SOPS credentials when using secrets. Load passphrase-protected SSH keys into
`ssh-agent`. Never put private keys or plaintext secrets in flake values that
would copy them into the Nix store.

## Application runbook

The planned runbook adds discoverable, named commands declared alongside a
target's deployment configuration. Commands execute inside the verified running
container, with its existing environment and secrets—no new deployment or one-off
container. Interactive consoles are explicit; ordinary commands work without a
terminal and propagate their exit status.

The configuration example and exact first-slice behavior are in
[DEVELOPMENT.md](DEVELOPMENT.md#runbook-first-slice).

## Development

OCaml is the active implementation. Preserve its working deployment engine and
safety checks while removing control-plane infrastructure. Historical C#,
Elixir/Phoenix, and MoonBit sources under [legacy/](legacy/README.md) are reference
material, not active dependencies.

```sh
nix develop . -c dune runtest --root ocaml
nix build .#nixploy
```

See [ocaml/README.md](ocaml/README.md) for implementation navigation and
[AGENTS.md](AGENTS.md) for repository agent instructions.
