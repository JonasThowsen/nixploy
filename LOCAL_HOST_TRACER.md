# Local-host discovery tracer

## Observable behavior

An authenticated operator opens the control plane and sees the containers visible
to the same local Podman user that runs nixploy. No repository, target, or service
record is required before the host becomes useful.

## Acceptance criterion

- The NixOS module enables Podman and runs nixploy as the rootless Podman owner.
- The connected LiveView executes one bounded local `podman ps -a --format json` probe.
- Managed and unmanaged containers are rendered together.
- Existing nixploy labels expose project, target, revision, slot, and deployment time.
- Repository links are shown when either nixploy or OCI source labels are present.
- Probe failures are visible and the operator can retry them.
- The primary empty state contains no manual repository, target, or service forms.

## What this proves

The installation host can be the first control-plane boundary. Host identity and
runtime state do not need to be copied into PostgreSQL before nixploy can observe
them. The existing deployment records and history remain available while this
onboarding direction is evaluated.

## Runtime ownership

Rootless Podman storage is per-user. The control plane only sees and controls
containers owned by its service user. The module therefore creates a normal,
lingering `nixploy` user by default and also permits selecting an existing
Podman-owning user. Running the combined web/worker process as `root` is not the
intended production profile.

## Discovery labels

New compatibility-CLI deployments write both legacy labels and the discovery
contract:

```text
io.nixploy.managed=true
io.nixploy.project=<project>
io.nixploy.target=<target>
io.nixploy.repository=<git remote>
io.nixploy.revision=<commit>
io.nixploy.deployed_at=<timestamp>
org.opencontainers.image.source=<git remote>
org.opencontainers.image.revision=<commit>
```

Older containers without a repository source remain visible as unlinked managed
workloads. Arbitrary containers remain visible as unmanaged workloads.

## Deliberately deferred

- GitHub App installation, repository metadata, and flake discovery
- Native local build and mutation adapters
- Persisted inventory, polling, and reconciliation
- Podman pod grouping beyond the container's reported pod name
- Split-role inventory collection through a worker boundary

The next tracer should connect one GitHub repository read-only and match it to a
labeled local workload without adding manual configuration forms.
