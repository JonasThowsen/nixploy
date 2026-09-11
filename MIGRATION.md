# Moving from the Nixploy service to the CLI

The CLI runs on your laptop or CI runner. It connects to an already-provisioned
Podman host over SSH. Caddy continues serving application traffic; removing the
Nixploy web service does not remove Caddy or your application containers.

## Before updating an existing installation

1. Finish or explicitly interrupt any active deployment and inspect its result.
   Do not overlap the old service's deployment engine with a new CLI invocation.
2. Stop and disable the old `nixploy.service`. Retire the old target-lease broker
   only after confirming that no old deployment client is using it. These are
   operator actions on the old service host, not steps the CLI performs remotely.
3. Back up the old SQLite database and retain its ownership and access controls.
   Use SQLite's backup facility if the database is open. Keep history as evidence;
   a historical success is not proof of the application's current health.
4. Preserve your repository origin, project name, target names, container labels,
   Podman secrets, Caddy routes, and server data. Changing these identities during
   migration can make an existing application look like a different deployment.

## Update configuration

Remove the old Nixploy NixOS module import and `services.nixploy` configuration
when updating the Nixploy flake input. The CLI-only package does not provide a
Nixploy web service. Leave the target's Podman and Caddy services configured.

Keep application deployment configuration in the application's flake. Remove the
obsolete `controlPlane` declaration and managed-authority flags from scripts.
Ordinary CLI targets no longer need a managed-application registration or a
production/nonProduction authority profile. Use an explicit `--target` on each
command rather than relying on an implicit production default.

Make the operator's SSH credentials, trusted host keys, and SOPS decryption keys
available locally. Load passphrase-protected SSH keys into `ssh-agent`. Use the
durable credential source, not a former service's ephemeral systemd credential
directory. Do not put private keys in the Nix store or copy them into the project.

Local CLI history belongs to the machine running the command. History from the
old service is not automatically distributed to laptops or CI runners. Preserve
that database separately if its old operation records remain useful.

### Legacy Podman secrets

New secrets carry repository, project, target, and resource ownership labels.
Older unlabelled secrets are not safely identifiable by name alone: cleanup
retains them, and deployment refuses to overwrite a same-name unlabelled secret.
Partially labelled or contradictory secret metadata is an ownership failure.

Before replacing a legacy secret, explicitly verify its provenance and every
container consuming it, preserve the encrypted source and decryption credentials,
and plan the change as an operator migration. Do not bulk-delete secrets by a
name prefix or remove secrets used by another application. The CLI does not
automatically adopt unlabelled secrets or request their plaintext for inspection.

## Verify before deploying

Build the new package and inspect its help, then evaluate your application flake
and inspect the exact target:

```sh
nix build .#nixploy
cli="$(readlink -f result)/bin/nixploy"
"$cli" --help

# Change to the application repository before these commands.
nix eval .#nixploy --json
"$cli" status --target production
"$cli" runbook --target production
```

Build and capture the executable path in the Nixploy repository; the final three
commands run in the application repository, in the same shell. Building alone
does not replace an older `nixploy` on PATH. Runbook listing only discovers
configured commands; it does not execute them.

Investigate any ownership, identity, host-key, or uncertain-state failure before
deploying. Do not use prune to force an existing deployment to fit a changed
identity. Never delete server data, Podman volumes, credentials, or the old state
database merely to complete the migration.

Once inspection matches the intended application and destination, deploy through
the CLI. Keep the old deployment service disabled. Recovery from an ambiguous
remote operation requires inspecting the target first; do not automatically
retry a deployment or runbook command that may already have changed it.
