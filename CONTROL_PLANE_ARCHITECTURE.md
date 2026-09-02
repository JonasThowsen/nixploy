# Nixploy control-plane architecture

**Status:** Proposed and independently reviewed. See
[`CONTROL_PLANE_ARCHITECTURE_REVIEW.md`](CONTROL_PLANE_ARCHITECTURE_REVIEW.md)
for the independent findings incorporated here. This specification is the
implementation gate; no production cutover is authorized until its acceptance
criteria are proven.

## Purpose

Nixploy has one trusted control plane hosted on the Netcup VPS. It is the sole
mutation authority for every managed application. The browser UI and every
project-installed CLI are operator clients of that service.

The control plane is not an application host. It remotely observes and deploys
to one or more Linux deployment targets.

## Goals

1. One managed application/target scope has one admission authority, durable
   operation history, active-operation registry, and authoritative lease owner.
2. The browser UI and CLI show the same operations, statuses, health
   observations, and compatibility errors.
3. A package, protocol, or configuration mismatch fails before admission,
   target-lease acquisition, build, secret, Podman, or Caddy effect.
4. Host metrics describe each deployment target, not the Netcup control-plane
   machine.
5. A project flake remains the declarative source of application configuration;
   it does not grant a local client mutation authority for a managed target.
6. Explicit local/offline work remains possible only for an un-managed,
   non-production target with a distinct coordination scope.

## Non-goals

- A generic job scheduler, worker fleet, remote shell, or plugin system.
- A metrics time-series database or alerting system. This specification covers
  bounded current observations and last-known freshness only.
- Automatic fallback from a failed control-plane request to direct local
  deployment.
- A source-upload exception for uncommitted managed-production changes.

## Canonical terms

The glossary in [`CONTEXT.md`](CONTEXT.md) defines control plane, operator
client, managed application, deployment target, deployment operation, and
target observation. In this specification, **managed** always means a
control-plane allowlisted application; it never means merely a local flake
containing a similarly named target.

## Components and authority

```text
project CLI ───────────┐
                       │ authenticated, versioned control-plane API
browser UI ────────────┼──────────────> Netcup control plane
                       │                    ├─ durable operation store
                       │                    ├─ authoritative lease broker
                       │                    ├─ managed source custody
                       │                    └─ target observation service
                       │
                       └──────── SSH/Podman/Caddy ──> deployment targets
```

### Control plane

The Netcup service owns:

- the managed-application allowlist and the binding from application key to
  repository identity, target, canonical resource key, and coordination scope;
- root-controlled source custody and exact revision validation;
- deployment admission, cancellation, durable operation history, resource
  state, and target-scoped leasing;
- all deployment credentials, SOPS identity, strict known-host data, Podman and
  Caddy effects;
- bounded target observations and their freshness state; and
- the versioned API contract consumed by operator clients.

A managed operation is never created on a client machine. SQLite durability,
active cancellation registration, and lease ownership live on the control-plane
host.

### Operator clients

The web UI is an embedded typed client shipped with the control-plane package.
It is always API-compatible with the server that served it, but it still uses
the same mandatory compatibility grant as external CLIs.

A project CLI is a typed remote client for managed targets. It may discover the
project identity and requested Git revision locally, but it must not execute
Git/Nix/Podman/Caddy/SOPS deployment orchestration for that target. Its status,
history, logs, metrics, cancellation, and deployment progress come from the
control-plane API.

For a managed target, a control-plane connection failure is an error. A CLI
must never retry by performing a direct deployment.

### Deployment targets

Deployment targets are the remote Linux hosts running Podman workloads. They
are reached only by the control plane using configured, strictly verified
credentials. A target can host multiple managed applications; observations are
grouped by canonical endpoint identity while containers and operations remain
scoped by application resource identity.

`Endpoint_identity` is a structured normalized value containing SSH host, port,
user, and configured host-key identity. It is never derived from a display
string such as `user@host:port`. Clients receive a separately redacted display
label.

## Source custody and managed deployment request

A managed deployment request contains only bounded identifying data:

- managed application key;
- requested target name;
- Git provenance identity;
- exact full committed SHA; and
- the client protocol version and required capabilities.

The server independently verifies every value against its allowlist and source
custody. A valid managed production entry has a root-owned, non-writable
repository, full branch reference, provenance identity, and a bounded-fresh,
root-owned evidence manifest binding the reference to its exact commit object.
A privileged mirror/update service atomically publishes the Git ref and fresh
evidence. The nixploy service reads this custody tree; it must not use bind-
mounted or ACL-shared developer checkouts as production authority.

The server requires the requested full SHA to match fresh custody evidence,
materializes exactly that object, evaluates the deployment configuration from
that revision, and checks the evaluated project, target, endpoint, and scope.
It persists that SHA in the admitted operation. A revision-less managed deploy
endpoint is not retained.

The browser obtains a full SHA from the server's current custody evidence and
submits the same immutable request as the CLI. If the evidence changes between
selection and admission, the request fails and the browser refreshes its
selection; it does not deploy an unspecified newer revision.

Uncommitted, locally modified, or unpushed source cannot be deployed to a
managed production target. The operator must first make the revision available
to the server-controlled repository. A future signed source-bundle workflow is
out of scope and requires a separate authority design.

## API compatibility and trust contract

### Trusted authority selection

A project flake may name a control-plane authority alias and managed application
key. It cannot supply an arbitrary URL to which the CLI sends credentials. The
CLI resolves the alias only through protected operator configuration containing
an exact HTTPS/Tailscale authority and pinned server identity or trust root.

The CLI rejects redirects, certificate/identity mismatches, unconfigured
authorities, and direct service connections that bypass the configured trusted
proxy boundary. Operator authentication is performed only over this trusted
transport. Deployment SSH keys, SOPS identities, and target credentials remain
on the control plane and are never read from project clients.

The production authority record is fixed at
`/etc/nixploy/control-plane-authorities.sexp`; there is no CLI, environment, or
project override for its path. The file and every parent directory must be
root-owned, non-symlinked, and not group/world writable. Its version-1 form is:

```lisp
((version 1)
 (authorities
  (((alias netcup)
    (uri https://control.example.com)
    (pinned_server_spki_sha256 BASE64_SHA256_OF_SERVER_SPKI)
    (trusted_proxy_authority https://control.example.com))))
```

A project may supply only the `nixploy.controlPlane.authorityAlias` and
`nixploy.controlPlane.managedApplicationKey` names. It never supplies a URI,
pin, credential destination, or authority-record path. Managed transport must
verify `pinned_server_spki_sha256` on the same TLS connection, reject redirects,
and require the configured trusted-proxy authority; system trust alone is not a
substitute for the pin. Until the WebSocket transport exposes that verification,
managed CLI operations fail closed with `NIXPLOY_PIN_UNSUPPORTED` after record
resolution.

### Mandatory negotiated grant

Every browser and CLI connection starts with versioned `Get_capabilities`.
The request declares client protocol major/minor and the capabilities required
for its intended command. The response includes:

- control-plane identity and package revision;
- API protocol major and supported minor range;
- accepted deployment-configuration schema versions;
- managed operation capabilities;
- server time and target-observation freshness policy; and
- an opaque, short-lived capability grant.

The server binds the grant to the authenticated identity, connection, negotiated
protocol version, granted capability set, server package revision, and expiry.
Every managed RPC rejects an absent, expired, or insufficient grant before
application admission. A reconnect performs a new handshake. This requirement
makes negotiation server-enforced rather than a bypassable client convention.

Machine-readable errors have stable codes and bounded human hints, including
`NIXPLOY_PROTOCOL_INCOMPATIBLE`, `NIXPLOY_CAPABILITY_UNAVAILABLE`,
`NIXPLOY_CONFIG_SCHEMA_UNSUPPORTED`, `NIXPLOY_UNTRUSTED_CONTROL_PLANE`, and
`NIXPLOY_SOURCE_CUSTODY_MISMATCH`.

| Condition | Result |
| --- | --- |
| Matching protocol major and required capabilities available | Request may continue. |
| Older client, newer server, requested capability retained | Request continues. |
| Newer client, older server, required capability absent | Reject with a clear server-upgrade-required error. |
| Different protocol major | Reject with `NIXPLOY_PROTOCOL_INCOMPATIBLE`. |
| Server cannot evaluate the requested config schema | Reject with `NIXPLOY_CONFIG_SCHEMA_UNSUPPORTED`. |
| Application, revision, target, provenance, or scope mismatch | Reject with `NIXPLOY_SOURCE_CUSTODY_MISMATCH` or authorization error. |

All rejection paths above occur before durable admission or a remote effect.
Existing per-RPC versions remain useful for additive API evolution, but do not
replace this session-level grant.

## Lease and durable lifecycle

The control-plane `Application` owns the broker client. A SQLite process lock is
not authoritative target leasing and is insufficient for managed deployment.

For a managed deployment, the order is:

1. Validate the capability grant and request before admission.
2. Durably record a requested operation with immutable application key, origin
   `control_plane`, full SHA, target, canonical endpoint, and scope.
3. Acquire the target-lease broker using the configured immutable authority and
   scope UUID plus the durable operation UUID.
4. Persist the broker authority, scope, generation, receipt, and identity as
   durable operation evidence.
5. While holding that lease, freshly revalidate source custody, evaluated
   configuration, target endpoint, scope, ownership state, and remote plan.
6. Mark remote state unknown before ambiguous effects, then run the bounded
   deployment/compensation sequence.
7. Persist a terminal success, failure, cancellation, or `Requires_review`
   outcome. Hold the lease through compensation.
8. Release only with the matching broker receipt after its clean evidence is
   durable. A clean receipt cannot retire another generation's dirty evidence.

A lost lease, dirty broker state, failed durability step, failed compensation, or
ambiguous remote effect produces `Requires_review`, not guessed success or
failure. This terminal automation state records reason class, last safe stage,
lease evidence, and an operator recovery reference. Startup and every new
admission reconcile interrupted rows and broker evidence before accepting work.
A blocked/dirty scope cannot be automatically taken over.

## Shared operation reads and updates

Managed operation rows contain an explicit origin/authority and exact managed
application key. Managed reads and cancellation require that key; they never
match legacy unkeyed local rows by target scope. Existing local history is
archived or displayed separately as pre-control-plane history.

The first transport uses bounded polling rather than an unbounded event stream:

- `Get_operation` returns one durable operation and a monotonic update sequence;
- `List_deployments`, `Get_status`, logs, and metrics return bounded pages;
- active operations may be polled at most once per second per client; and
- terminal operations are read from durable storage after reconnect or service
  restart.

A later subscription protocol must define cursor, ordering, replay, reconnect,
and backpressure rules before it replaces polling.

Cancellation is a control-plane request scoped by managed application and
operation ID. A client cannot signal a local process and claim that it cancelled
a managed deployment.

## Target health and runtime observations

Target observations are a read-only control-plane capability, independent of a
deployment operation.

An Application-owned endpoint-keyed observation cache provides one single-flight
host probe per `Endpoint_identity` every 10 seconds. It has a 30-second stale
TTL, a 15-second probe timeout, at most 32 coalesced waiters, a 256 KiB command
output cap, and 4 KiB bounded/redacted diagnostic text. Per-application Podman
and health observations are gathered separately and joined to that one host
sample.

Each response has one explicit state:

- `Fresh { observed_at }` — observation completed within the interval;
- `Stale { observed_at; error }` — the last good sample is within the TTL but
  refresh failed; or
- `Unavailable { error }` — no usable sample exists.

A host probe gathers bounded CPU utilisation from two `/proc/stat` samples,
memory, load, uptime, root filesystem capacity, and verified runtime container
stats. The server also runs configured application health checks where present.
No target-side monitoring agent is required for the first implementation.

A probe failure never fabricates health and does not alter deployment history or
resource state. The UI and CLI use the same observation response. If SSH polling
later becomes insufficient, a target agent may be introduced behind this
observation boundary without exposing it to operator clients.

## Local and non-production mode

Direct local deployment, if retained, is a separately named non-production
mode. It requires an explicit local contract and a coordination scope that can
never equal a managed control-plane scope. It cannot use a managed application
key, target profile, source custody record, state database, operation origin, or
target lease.

The default `deploy`, `status`, `history`, logs, metrics, and cancellation
commands for a managed target always use the control plane. Managed CLI commands
ignore local `--state-db` input and are process-trace tested to spawn no local
Nix, SSH, Podman, Caddy, or SOPS deployment process.

## Upgrade, rollback, and migration gates

The Netcup NixOS flake lock is an independent release pin. Pushing nixploy does
not upgrade the service. Each control-plane rollout must:

1. build and test the selected package revision and an upgrade from a copied
   production SQLite/custody-state fixture;
2. back up SQLite and broker custody/dirty evidence before migration;
3. apply only forward-compatible schema migrations, with the new service
   refusing unsupported existing schema and the previous binary refusing a newer
   schema rather than corrupting it;
4. restart, reconcile interrupted operations and lease evidence, and accept no
   new requests until reconciliation succeeds;
5. update the Netcup flake input and deploy the NixOS generation; and
6. retain the prior NixOS generation for package rollback. Database rollback is
   an explicit operator restore from the pre-upgrade backup, never a silent old
   binary startup.

## Migration plan

1. **Custody and broker foundation:** replace any bind-mounted developer Git
   authority with root-owned custody plus atomic evidence publication. Configure
   and prove the target-lease broker before managed CLI mutation.
2. **Handshake tracer:** add `Get_capabilities`, trusted authority selection,
   server identity, enforced grants, and machine-readable errors. Prove a
   compatible read-only CLI status request and every rejection path.
3. **Shared reads:** route managed CLI status, history, logs, metrics, and
   bounded operation polling through the control plane. Migrate/fence local
   legacy history by explicit origin.
4. **Endpoint observations:** add the endpoint cache, freshness model, and
   one-probe-per-endpoint tests.
5. **Managed deployment tracer:** replace revision-less deploy with immutable
   revision admission; route one managed CLI deployment to the server. Prove no
   local deployment subprocess starts.
6. **Managed cancellation:** route CLI cancellation through the same server
   operation registry and durable terminal state.
7. **Direct-mode fence:** retain or remove explicit non-production direct mode;
   in either case, prove it cannot collide with a managed scope.

Each phase is independently deployable and preserves the existing browser path
until the replacement client path is proven.

## Acceptance criteria

- A browser and two different CLI package revisions render the same server
  operation ID, stage, history, resource state, and target observation for one
  managed application.
- The server rejects a managed RPC without a valid capability grant before
  SQLite admission, broker acquisition, source preparation, or remote process
  execution.
- An incompatible CLI fails before SQLite admission, target-lease acquisition,
  source preparation, or remote process execution.
- A managed CLI deployment causes deployment subprocesses only on the Netcup
  control plane; the CLI performs no local deployment subprocess.
- A target shared by multiple applications receives no more than one host probe
  per 10-second interval while still returning each application's runtime stats.
- Loss of target connectivity returns explicitly stale or unavailable health
  data and leaves the latest deployment operation intact.
- Source custody or revision evidence changes after browser selection cause a
  pre-effect rejection rather than a changed-revision deployment.
- Direct non-production mode, if present, rejects a managed application key or
  matching coordination scope.
- Browser and CLI cancellation of the same operation converge on the same
  durable terminal record.
- Upgrade and rollback tests prove schema refusal, custody/broker backup,
  startup reconciliation, and no new admission before reconciliation succeeds.

## Implementation constraints

The implementation keeps the existing dependency direction:

```text
pure domain -> Application -> adapters
                         ^
                    RPC / CLI clients
```

The server-side `Application` remains the only deployment orchestrator. The
CLI becomes a transport adapter for managed operations rather than gaining a
second copy of source, deployment, observation, or lease orchestration.

This architecture retains strict SSH host-key verification, explicit argv,
secret redaction and stdin handling, bounded diagnostics, ownership-label
verification, and fail-closed durable lifecycle rules described in
[`DEVELOPMENT.md`](DEVELOPMENT.md) and
[`PRODUCTION_LIFECYCLE_V1.md`](PRODUCTION_LIFECYCLE_V1.md).
