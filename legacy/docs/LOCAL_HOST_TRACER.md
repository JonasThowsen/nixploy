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

## Local workload observability increment

### Observable behavior

An authenticated operator selects a discovered workload and sees a fresh local
Podman inspection plus a bounded recent log snapshot. This works for managed and
unmanaged containers without repository, target, or service records.

### Acceptance criterion

- Inspection uses a fixed `podman container inspect` argument vector with a
  15-second timeout and a 1 MiB output bound.
- Logs use a fixed `podman logs --tail 200` argument vector with a 15-second
  timeout and a 64 KiB output bound.
- Container/image identity, labels, runtime timestamps, health metadata, and
  published ports are parsed from inspect JSON.
- Inspect and log failures render in the LiveView without terminating it.
- Raw log content remains ephemeral LiveView state and is not stored in
  PostgreSQL.

### What this proves

The dashboard can cross the real local rootless Podman boundary for an
operator-selected container and return useful runtime evidence without a
configuration database. The selected identifier must come from the current
inventory, and subprocess arguments are never shell-interpolated.

## Local health observation increment

### Observable behavior

An authenticated operator requests a health observation for a selected managed
workload and sees its inspected container state, bounded loopback HTTP result,
observation timestamp, and a useful failure reason.

### Acceptance criterion

- The container is re-inspected and must still carry positive nixploy-managed
  labels before any HTTP request is made.
- A localhost port is derived only from published Podman bindings or the
  allowlisted `PORT` runtime variable; environment values are never rendered.
- Only the fixed `/health` and `/ready` candidates are tried, each with a
  5-second curl limit, 7-second command timeout, and 4 KiB output bound.
- Stopped containers, missing ports, non-2xx responses, command failures, and
  timeouts remain visible without crashing the LiveView.
- The observation remains ephemeral because this tracer demonstrates no value
  from a speculative persisted monitoring subsystem.

### What this proves

Locally declared runtime metadata is enough to observe Jomat's `/health` and
Salgsoversikt's `/ready` endpoints without repository onboarding or duplicated
service forms. The fixed endpoint candidates are deliberately narrow until a
native deployment can derive the exact path from the project flake.

## Production evidence

On 2026-07-30 the packaged release was exercised through the authenticated
Tailscale UI and directly as the `nixploy` runtime user:

- Jomat and Salgsoversikt appeared from the real rootless Podman store; root's
  Podman store remained empty.
- Opening Jomat showed its full container/image identity, revision, timestamps,
  green slot, and a bounded 26-line log snapshot.
- Opening Salgsoversikt showed the same runtime metadata and a bounded 200-line
  log snapshot.
- Neither detail probe rendered an inspect or log error, and no raw log content
  was inserted into PostgreSQL.
- UI-triggered loopback observations returned HTTP 200 for Jomat on port 4003
  and Salgsoversikt on port 4005 with fresh timestamps.
- The deployed service remained bound to `127.0.0.1:4000` as `nixploy`; all four
  required public health/readiness checks returned HTTP 200 after activation.

Malformed output, truncation, command failure, timeout, unmanaged refusal, and
LiveView failure rendering are covered by the automated suite because inducing
a production Podman outage would unnecessarily risk both applications.

## Deliberately deferred

- GitHub App installation, repository metadata, webhooks, and revision selection
- Native local build and mutation adapters
- Persisted inventory, polling, reconciliation, and raw log storage
- Log following, search, retention, and secret-aware redaction
- Podman pod grouping beyond the container's reported pod name
- Split-role inventory collection through a worker boundary

The next tracer should design and prove one native no-GitHub deployment from an
immutable local input, deriving application configuration from its project flake.
