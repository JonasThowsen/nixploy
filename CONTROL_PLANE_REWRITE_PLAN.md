# nixploy Control Plane Rewrite Plan

> **Historical document:** This records the original rewrite architecture and
> delivery plan. It is not current product scope. [`ROADMAP.md`](ROADMAP.md)
> contains the deliberately narrow OCaml control-plane backlog, and
> [`UI_DIRECTION.md`](UI_DIRECTION.md) defines the operator interface.

## Objective

Evolve nixploy from a small deployment CLI into a self-hosted control plane for deploying Nix-built OCI images to ordinary Podman servers.

The system should let an operator connect a Git repository containing a Nix flake, register deployment targets, attach an application to a target and domain, deploy immutable revisions, and inspect deployment status and logs from the web.

NixOS infrastructure provisioning remains outside this project. A target may be provisioned by `nixos-infra`, another NixOS configuration, or manually, as long as it satisfies nixploy's target contract.

## Development method

Use a tracer-bullet approach for every feature. Implement each capability first as the smallest useful end-to-end slice with one observable behavior and a concrete acceptance criterion. A tracer should cross the real boundaries needed to prove the path and become a production foundation, not a disposable prototype.

Prefer a thin vertical path over completing disconnected horizontal layers. Exercise the production artifact or a deployed-style build where practical, add focused tests around invariants and failure-prone boundaries, and broaden behavior only after the basic path works and can be evaluated. Temporary shortcuts must be explicit, safe, reversible, and recorded with an actionable inline `TODO(tracer)` at the code boundary where functionality is deferred. Broader work without a meaningful code location belongs in the roadmap or backlog. Refactor after a working slice reveals actual coupling rather than introducing abstractions for hypothetical needs.

For the current walking skeleton, this means replacing simulation with one narrow real deployment path end to end before expanding every execution adapter or adding more simulated capabilities.

## Product boundary

### nixploy owns

- Git repository and revision selection
- Nix evaluation and OCI image builds
- Application deployment to Podman over SSH
- Application secrets and runtime configuration integration
- Domain and ingress attachment
- Health verification and rollback
- Deployment jobs, history, status, logs and cancellation
- Target-level deployment serialization
- Authentication, authorization and audit records

### nixploy does not own

- VPS creation
- General NixOS configuration management
- Host upgrades or activation
- Network and DNS provisioning beyond explicit application integrations
- A general-purpose secrets vault
- Kubernetes-style cluster scheduling

## Architectural decision

Implement the rewrite in Elixir using Phoenix, Ecto, PostgreSQL and Oban OSS.

Keep one modular codebase with separately runnable roles:

- `web`: HTTP, authentication, UI, API and real-time updates
- `worker`: builds, deployments, health checks and log collection
- `all`: combined web and worker mode for simple installations
- `cli`: thin interface over the same deployment domain logic

PostgreSQL is the durable source of truth and coordination boundary. OTP processes provide supervision and responsiveness, but durable operation state must survive process and node restarts.

Distributed Erlang, Redis, Kubernetes and a microservice architecture are not initial requirements.

## Core domain model

### Repository

A Git repository and its access configuration. Deployments always resolve a branch or tag to a specific commit before work begins.

### Application

A deployable application definition associated with a repository and flake output. An application can have multiple target attachments.

### Target

A Podman-capable server reachable by a worker. It advertises capabilities such as ingress, rootless Podman and supported deployment strategies.

### Service

An application attached to a target with runtime configuration such as domain, health check, environment, secrets and deployment strategy.

### Deployment

An immutable request to deploy a particular Git commit and normalized service configuration. It records attempts, events, artifacts and the final outcome.

### Operation event

An append-only record of deployment progress, structured output, warnings and failures. Ordinary relational tables retain current state; full event sourcing is not planned.

## Deployment lifecycle

A deployment follows an explicit persisted state machine:

```text
queued
-> acquiring_target
-> fetching_source
-> evaluating
-> building
-> preparing_target
-> deploying
-> switching_ingress
-> verifying
-> succeeded | failed | cancelled
```

Each stage must define:

- persisted inputs and outputs
- idempotency behavior
- cancellation points
- retry behavior
- structured failure information
- safe recovery after worker termination

Every deployment is pinned to a Git commit, Nix store output and OCI image identity or digest. A retry must not silently resolve a newer branch head.

## Concurrency and cancellation

Deployments and other mutating operations are serialized per target or service using PostgreSQL-backed leases with heartbeats, expiry and fencing tokens. Correctness must not depend solely on queue uniqueness or a long-held database connection.

Cancellation is cooperative and durable:

1. Record a cancellation request in PostgreSQL.
2. Notify the active worker.
3. Stop work between stages.
4. Terminate active local commands through an OS process group or systemd scope.
5. Attempt cleanup of identified remote operations.
6. Record whether cancellation completed cleanly or left resources requiring reconciliation.

## Logs and real-time updates

Workers persist deployment events before publishing notifications. Web processes fetch committed events and broadcast them to clients through Phoenix PubSub or LiveView.

PostgreSQL notifications can wake web processes without requiring distributed Erlang. Full build and application logs should use a retention-aware artifact store:

- shared filesystem for the simple single-host deployment
- optional S3-compatible storage for separated hosts

PostgreSQL stores metadata and may retain bounded recent log chunks for immediate display.

## Security model

The web role must not hold deployment SSH keys, SOPS keys or privileged target credentials. Workers run under a separate identity and receive only the credentials required for their assigned targets.

Repository evaluation and builds are trusted-code execution unless performed in a stronger external sandbox. Nix build sandboxing alone is not treated as a complete boundary for untrusted repositories.

Required practices include:

- strict SSH host-key verification
- no shell interpolation for commands
- bounded command environments
- secret redaction in events and logs
- isolated build workspaces
- resource and execution-time limits
- rootless Podman where possible
- explicit repository and target authorization
- auditable user and worker actions

Secrets should initially be supplied through files, systemd credentials, SOPS integration or an external provider. nixploy should store references and metadata rather than becoming a secrets vault.

## Relationship to the existing CLI

The current C# implementation defines useful deployment behavior and tests, particularly around:

- normalized flake configuration
- Podman-over-SSH deployment
- SOPS dotenv secrets
- pre-start commands
- project-scoped resources
- Caddy blue/green routing
- health checks

These semantics should be documented and covered by black-box compatibility tests before replacement.

The rewritten CLI and worker must share the same Elixir domain implementation. The web worker should not permanently shell out to a separately evolving CLI. During migration, invoking the existing CLI is acceptable as a temporary adapter.

## Proposed module boundaries

```text
Nixploy.Accounts
Nixploy.Repositories
Nixploy.Applications
Nixploy.Targets
Nixploy.Services
Nixploy.Deployments
Nixploy.Operations
Nixploy.Health
Nixploy.Logs
Nixploy.Execution
Nixploy.Adapters.Git
Nixploy.Adapters.Nix
Nixploy.Adapters.SSH
Nixploy.Adapters.Podman
Nixploy.Adapters.Caddy
Nixploy.Adapters.Sops
NixployWeb
```

These are internal boundaries in one application, not separately deployed services.

## Delivery phases

### Phase 0: Preserve current behavior

- Document the current flake configuration schema and deployment semantics.
- Add end-to-end or fixture-based compatibility tests.
- Identify behavior to retain, change or remove.
- Define a versioned normalized configuration contract.

### Phase 1: Elixir execution core and CLI parity

- Create the Mix project and core module boundaries.
- Implement a typed command runner with streaming output and cancellation.
- Port Git/Nix configuration loading and Podman SSH operations.
- Port secrets, health checks and Caddy blue/green deployment.
- Reach CLI parity for `deploy` and `prune`.
- Add `status` and `logs` using the new domain interfaces.

### Phase 2: Durable deployment engine

- Add PostgreSQL, Ecto and migrations.
- Add repositories, applications, targets, services and deployments.
- Add Oban queues and persisted deployment state transitions.
- Implement per-target leases and fencing.
- Implement durable cancellation and retry policies.
- Persist operation events and deployment artifacts.

### Phase 3: Initial web control plane

- Add Phoenix and authentication.
- Add repository, target and service management.
- Add deployment creation, history and details.
- Stream build and deployment progress in real time.
- Add cancellation, retry and rollback actions.
- Add role-based authorization and audit records.

### Phase 4: Application operations

- Show observed container and ingress status.
- Stream and search application logs.
- Add scheduled and on-demand health checks.
- Add one-off tasks and remote command execution with authorization.
- Add deployment retention and cleanup policies.

### Phase 5: Packaging and hardening

- Provide a Nix flake and packages.
- Provide a NixOS module for combined and split roles.
- Provide an OCI image.
- Document PostgreSQL backup and restore.
- Add upgrade and migration tests.
- Add worker isolation and credential-management guidance.
- Perform a security review of command execution and repository trust boundaries.

## Initial self-hosting profile

The smallest supported installation should contain:

```text
nixploy web + worker
PostgreSQL
shared local artifact directory
```

A split installation can run web and workers as separate users, containers or hosts while using the same PostgreSQL database and an S3-compatible artifact store.

## Early decisions to validate

- Whether the existing `.#nixploy` output remains the public configuration contract
- Whether domains and Caddy routing belong in the service declaration or a pluggable ingress adapter
- Whether workers build locally, use remote Nix builders, or support both
- How SSH and SOPS credentials are assigned to workers without storing private material in PostgreSQL
- The exact lease granularity: target, service, or separate resource classes
- Artifact and log retention defaults
- Whether the standalone CLI needs a bundled Erlang runtime outside Nix-based distribution

## Non-goals for the first release

- Managing arbitrary NixOS machine configuration
- Multi-tenant untrusted builds
- General cluster scheduling
- Automatic VPS or DNS provider provisioning
- A plugin ecosystem with unstable public internals
- Supporting multiple databases
- Requiring distributed Erlang
- Replacing Git as the declarative source of truth
