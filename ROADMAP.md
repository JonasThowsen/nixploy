# nixploy product roadmap

## Purpose

This is the current priority and delivery roadmap for nixploy. It supersedes the
older phase ordering in `CONTROL_PLANE_REWRITE_PLAN.md` where that plan assumes
GitHub onboarding or database-owned application configuration. The rewrite plan
remains useful architectural history; this document determines what to build
next.

The roadmap is intentionally organized as observable tracer slices rather than
calendar estimates or broad horizontal layers. Each slice must cross the real
boundaries needed to prove useful behavior, pass its acceptance checks, and be
committed and deployed independently before the next slice broadens it.

## Product direction

nixploy is a self-hosted operational control plane for applications deployed by
nixploy.

It should let an operator:

- understand what is running and whether it is healthy;
- deploy an immutable application input;
- follow deployment progress and investigate failures;
- roll back safely to a previously healthy deployment;
- inspect bounded logs, runtime metadata, ingress state, and operational history;
- run explicitly declared operational tasks where the project flake permits it;
- perform the same policy-protected operations from the web UI and, later,
  through an agent-facing MCP server.

The control plane remains small enough to run on one production VPS but keeps
boundaries that permit web and worker roles to separate when demonstrated load
or credential isolation requires it.

## Non-negotiable principles

### Self-hosted through Nix

- Nix packages the release and its runtime tools.
- NixOS owns the service user, PostgreSQL, Podman, Caddy, Tailscale, filesystem
  permissions, service lifecycle, and host-level recovery.
- Phoenix runs unprivileged as `nixploy` and binds only to loopback.
- Root SSH remains an infrastructure activation and recovery boundary, not an
  application-operation path.

### Tailscale is the network identity boundary

- The production UI remains private behind Tailscale Serve.
- Tailscale identity is accepted only from a loopback listener behind the
  trusted proxy.
- Application authorization still resolves a provisioned operator and records
  an actor for every sensitive operation.
- A future MCP transport must remain tailnet-only by default. If clients require
  access beyond the interactive Tailscale identity flow, standards-based OAuth
  must be added deliberately before widening the listener or trust boundary.

### Project flakes own application configuration

Project flakes own deployable application intent, including:

- image output;
- command and environment templates;
- network and port behavior;
- blue/green slots;
- domain and health path;
- pre-start commands and declared operational tasks;
- references to project secrets.

The web UI must not add editable repository, target, service, domain, port, or
health forms that become a second configuration source.

### NixOS and PostgreSQL have distinct responsibilities

NixOS owns host infrastructure. PostgreSQL stores operational facts:

- immutable input identities and derived configuration digests;
- deployment requests, stages, events, outcomes, and cancellation state;
- image/container/ingress observations;
- rollback relationships;
- audit events and confirmation records;
- bounded log/artifact metadata where persistence proves useful.

Raw project configuration and decrypted secrets are not copied into PostgreSQL.

### Mutations fail closed

- Commands use fixed argument vectors, explicit timeouts, bounded output, and
  cancellation-aware execution.
- Only positively identified nixploy-managed resources may be mutated.
- A replacement is never routed before its exact declared health check passes.
- Candidate failure leaves the previously routed healthy slot untouched.
- Destructive or high-impact UI and agent actions use explicit confirmation.
- Failures and partial side effects remain visible and reconcilable.

### Utility-first, mobile-first UI

The UI is an operational tool, not a decorative dashboard. The canonical
information architecture, responsive navigation, visual language, interaction
rules, implementation conventions, and review checklist live in
[`UI_DIRECTION.md`](UI_DIRECTION.md).

Every new operator workflow must:

- work at a narrow mobile viewport before being considered complete;
- use touch-sized controls and avoid hover-only behavior;
- preserve the most important state, failure, and action above the fold;
- render logs and long identifiers without breaking the page width;
- make dangerous actions visually distinct and require confirmation;
- provide stable URLs for workloads, deployments, and operations;
- remain useful under slow commands, stale observations, and explicit errors.

Desktop layouts may add density, but must not introduce capabilities unavailable
on mobile.

## Current production baseline

The following behavior is already proven:

- declarative NixOS installation and release migrations;
- unprivileged loopback-only Phoenix service;
- Tailscale identity-only operator authentication;
- local rootless Podman discovery without registration forms;
- clear managed/unmanaged classification from labels;
- workload details, bounded ephemeral logs, and explicit command failures;
- bounded local health observations;
- persisted deployment history, operation events, cancellation, leases, audit,
  and independent verification for the compatibility path;
- Jomat and Salgsoversikt running in the `nixploy` Podman store while root owns
  no application containers.

The compatibility adapter remains available as a recovery path. Native local
deployment, failure preservation, exact rollback, and no-secret flake-declared
pre-start execution are proven. Worker-only credential handoff remains the next
boundary before native production adoption.

## Delivery method and quality gates

Before each slice:

1. State one operator-visible behavior.
2. State a concrete end-to-end acceptance criterion.
3. Identify the real UI, database, Nix, Podman, Caddy, and network boundaries it
   must cross.
4. Implement the smallest production-quality vertical path.
5. Exercise it against real rootless Podman and the packaged UI.
6. Record what was proven and mark deferred boundaries with actionable
   `TODO(tracer)` comments.
7. Commit, push, deploy when appropriate, and verify production health before
   broadening the slice.

Each implementation slice must pass focused tests, the complete Elixir suite,
formatting, warnings-as-errors compilation, relevant Nix checks/builds, and any
legacy C# tests when that adapter changes.

---

# Milestone 1 — Native local deployment and rollback

**Goal:** replace the legacy adapter one complete local workflow at a time while
preserving a known rollback path.

## Slice 1.1 — Immutable local input and derived configuration

**Implementation status:** completed on the control-plane rewrite branch. The
slice now crosses authenticated LiveView, bounded local Nix verification and
evaluation, PostgreSQL operation/audit persistence, immutable-input history,
and a stable mobile-safe detail route. It intentionally enqueues no worker job
and performs no Podman or Caddy mutation.

**Observable behavior**

An operator stages an existing Nix store source and sees its verified store path,
NAR hash, project, selected target, image output, slot configuration, domain,
health path, and canonical configuration digest in the web deployment history.
No deployment mutation occurs yet.

**Acceptance criterion**

- A bounded `nix path-info --json -- <path>` verifies an existing source under
  `/nix/store` and returns its NAR hash.
- A bounded `nix eval --json --no-write-lock-file <path>#nixploy` derives schema
  `v0.2` configuration from that exact immutable path.
- The database stores input identity, selected target, normalized derived
  snapshot, and digest as immutable operation data.
- No repository, target, service, domain, slot, port, or health form is added.
- Invalid paths, changed hashes, unsupported schemas, ambiguous targets, and
  oversized/timeout output render useful failures.
- The staged input is visible from a mobile deployment detail page.

This is the next implementation slice. Its detailed constraints are in
`NATIVE_LOCAL_DEPLOYMENT_TRACER.md`.

## Slice 1.2 — No-secret native blue/green fixture

**Implementation status:** completed and exercised against the packaged
production control plane with the no-secret fixture. A first operation created
the isolated managed route and blue slot; a second operation selected green as
the inactive slot, built and loaded the persisted image, passed the exact
`/health` check, switched the identified Caddy proxy to `127.0.0.1:18081`, read
back container and ingress identity, and stopped blue. Existing application
projects were excluded by positive project/target identity.

**Observable behavior**

An operator deploys one immutable no-secret fixture. The inactive rootless slot
starts, becomes healthy, and receives traffic only after an identified Caddy
upstream switch.

**Acceptance criterion**

- The image is built from the persisted store path and loaded into local Podman
  as `nixploy`.
- The current Caddy upstream and active slot are read before mutation.
- An unmanaged name collision or ambiguous managed identity fails closed.
- Only the inactive managed slot is replaced.
- The candidate's image ID, state, labels, logs, and exact flake-declared health
  endpoint are observed.
- Caddy switches only after a bounded 2xx health result.
- Deployment stages and failure details stream to desktop and mobile UI.
- The compatibility adapter remains available.

## Slice 1.3 — Failure preservation and rollback

**Implementation status:** completed and exercised against the packaged
production control plane. The executor now verifies the currently routed slot
before mutation, reconciles an uncertain Caddy mutation, and restores/read-backs
the previous upstream after post-switch verification failure. Build, start,
health, and Caddy failures are covered at the bounded command boundary. A real
unhealthy candidate failed before switching while the healthy blue fixture
remained routed. A subsequent rollback rebuilt the exact prior input and image,
started its persisted green slot, switched only after health, independently
verified the result, and stopped blue. Repeating the same rollback failed with a
clear already-active result.

**Observable behavior**

A failed candidate leaves the current healthy slot routed, and an operator can
roll a successful deployment back to its previous verified image/configuration.

**Acceptance criterion**

- Injected build, start, health, and Caddy-switch failures preserve the old
  upstream.
- Rollback references an exact prior store path, NAR hash, image ID, derived
  config digest, and slot—not a branch or mutable tag.
- Rollback follows the same start, health, switch, and independent-verification
  path as deployment.
- Progress, success, failure, actor, and rollback relationship are persisted and
  audited.
- Repeated rollback requests are idempotent or fail with a clear current-state
  explanation.

## Slice 1.4 — Project credentials and pre-start actions

**Implementation status:** completed. Immutable flake snapshots retain encrypted
SOPS store-path references and bounded fixed pre-start argv, never decrypted
values. Production now runs separate web and worker OS processes. Only the
worker receives the host SSH identity through a systemd credential namespace;
the web mount namespace cannot read `/run/credentials`. The worker derives an
age identity, decrypts bounded dotenv content, creates operation-scoped labeled
Podman secrets through stdin, and injects them into pre-start and candidate
containers. The focused UI shows only credential-file and action counts on the
existing deployment confirmation and timeline.

Credential input `ca0b6e95-402b-45e9-a6a3-08d2acd84722` and successful operation
`d0d16605-1fc7-4c25-a4d4-6bebbc143bfa` proved worker decryption, secret
installation, pre-start access, candidate access, exact health, ingress switch,
and independent readback. Failure input
`18fe7b8b-e1bd-4741-9231-f10e3ee7321f` and operation
`021323a4-4a79-4d0c-8b5c-8e0faafba02f` deliberately printed the decrypted value
before exiting 23. Persisted failure contained `[REDACTED]`, emitted no starting
or switching stage, created no green candidate, and left the healthy blue
upstream selected. PostgreSQL data, LiveView HTML, events, audits, and production
journals contained no plaintext fixture value. Test containers, routes, images,
and operation-scoped secrets were removed after verification; durable evidence
remains.

**Observable behavior**

A project with encrypted secrets and pre-start commands can use the native path
without storing decrypted material in PostgreSQL or exposing it to the web
process.

**Acceptance criterion**

- Flake declarations provide references, not secret values.
- Credential access occurs only in the worker/runtime identity that requires it.
- Secret values are redacted from retained command output and events.
- Pre-start commands use fixed argv and complete before the candidate starts.
- Failure prevents ingress switching and preserves the active slot.
- One credential-backed production-style fixture deploys without changing its
  flake-owned configuration into database fields; real application adoption is
  reserved for Slice 1.5.

## Slice 1.5 — Native production adoption

**Observable behavior**

One existing production application is deployed and rolled back through the
native path while the other remains available.

**Acceptance criterion**

- Existing legacy labels/resource prefix are adopted only when project and
  target identity are unambiguous.
- Public health remains available throughout deployment and rollback.
- The exact deployment and rollback inputs are visible in history.
- Root's Podman store remains empty.
- The legacy adapter is retained until this production exercise and recovery
  path are documented.

**Milestone exit:** a real application has completed native deploy and rollback;
the old healthy slot survives injected failure; the compatibility adapter is no
longer required for that application's normal path.

---

# Milestone 2 — First-class operational web interface

**Goal:** make deploy, rollback, observation, and investigation fast and safe on
mobile and desktop.

UI improvements should accompany Milestone 1 slices. This milestone completes
the information architecture after the native semantics are proven.

## Slice 2.1 — Stable application and deployment pages

**Tracer status:** implemented ahead of the production-adoption slice. Primary
navigation now uses Overview, Applications, Releases, and Deployments. The
application workspace reads real rootless Podman state and presents automatic
health, point-in-time CPU/RAM/process/network/disk metrics, bounded logs, active
slot, revision, and technical evidence through one mobile-safe view. Releases
lead with deployable application intent; host-local source registration is
collapsed under an explicitly advanced bridge. Historical low-level URLs remain
as compatibility aliases for retained bookmarks.

- Add stable routes for application and deployment details instead of continually
  expanding one dashboard.
- Keep current state, health, active slot, revision, and primary action visible
  on small screens.
- Preserve refresh/error state without losing the selected workload.
- Link observations, deployments, rollback ancestry, and audit events.

## Slice 2.2 — Deployment action and progress experience

- Select only immutable staged inputs.
- Show derived flake configuration read-only before confirmation.
- Stream stage progress and bounded output.
- Distinguish queued, active, cancelling, failed, succeeded, and reconciliation
  states visually and accessibly.
- Keep cancellation and retry semantics explicit.

## Slice 2.3 — Rollback experience

- Present verified historical candidates with image/config identity and health
  evidence.
- Preview what will change and what remains active.
- Require deliberate confirmation.
- Show rollback as a new audited operation, not a history rewrite.

## Slice 2.4 — Investigation workspace

**Tracer status:** the first point-in-time application workspace is implemented.
Historical metric sampling, charts, alerts, log follow/search, retained
observations, and diagnostic bundles remain deferred at their real collection
boundaries until production use establishes useful windows and retention.

- Combine bounded logs, health attempts, container state, image identity,
  ingress state, deployment events, and timestamps around one workload.
- Add server-side filtering and bounded time windows before log search breadth.
- Persist logs only after retention, redaction, and demonstrated operational
  value are defined.
- Make copying identifiers and downloading bounded diagnostic bundles practical
  on mobile.

## Slice 2.5 — Flake-declared operational tasks

- Expose only named argv-based tasks declared by the project flake.
- Never provide an arbitrary web shell.
- Require authorization, bounds, audit, and confirmation according to impact.
- Stream bounded output and persist operation outcome.

**Milestone exit:** an operator can deploy, follow progress, diagnose failure,
inspect bounded evidence, and roll back entirely from a polished mobile UI.

---

# Milestone 3 — Self-hosting and operational hardening

**Goal:** make the control plane itself recoverable and boring to operate.

## Slice 3.1 — Backup and restore proof

- Document and automate PostgreSQL backup under NixOS-owned credentials.
- Restore into a clean production-style instance.
- Verify operators, immutable inputs, deployment history, events, audit, and
  observations after restore.
- Keep raw application logs outside the database unless retention requires them.

## Slice 3.2 — Upgrade and migration proof

- Build old-to-new release migration checks.
- Verify identity provisioning, readiness, and rollback after NixOS activation.
- Record the running package/version in the UI without giving the web process
  host-upgrade privileges.

## Slice 3.3 — Recovery and reconciliation

- Reconcile interrupted deployments from PostgreSQL and observed Podman/Caddy
  state.
- Distinguish safe retry, already applied, rollback available, and manual
  intervention required.
- Document deliberate break-glass password recovery while preserving Tailscale
  as the normal identity boundary.

## Slice 3.4 — Credential and role separation

- Separate web and mutation credentials when the demonstrated threat model or
  deployment shape requires it.
- Keep web reads and operation requests useful when a worker is temporarily
  unavailable.
- Preserve PostgreSQL as the durable coordination boundary.

**Milestone exit:** backup/restore, upgrade, interrupted-operation recovery, and
identity recovery have all been exercised against packaged releases.

---

# Milestone 4 — Incremental Ash migration

**Goal:** make Ash actions and policies the canonical backend interface used by
the UI, workers, and later agent surfaces without a big-bang rewrite.

Ash migration begins only after native deployment, rollback, and core operator
workflows have stable semantics. Current Ecto contexts remain valid until one
bounded domain is fully replaced.

## Migration rules

- Migrate one demonstrated capability at a time, preferably over existing tables.
- Keep behavior and audit compatibility tests around every migrated action.
- Model operations as Ash actions rather than recreating the existing context
  layer behind generic CRUD.
- Use policies with the real operator actor for every UI, worker, and future MCP
  call.
- Do not expose raw resources merely because AshAI can generate tools from them.
- Do not introduce `ash_ai` or `ash_lua` into mutation paths before the owning
  Ash actions and policies are proven without an LLM.

## Slice 4.1 — Read-only operations domain

Migrate the lowest-risk useful surface first:

- workload inventory projections;
- workload details;
- health observations;
- bounded log snapshot requests and results.

The web UI must use these Ash actions before they become agent-callable.

## Slice 4.2 — Deployment history and immutable inputs

Model immutable deployment input, derived config digest, deployment, event,
artifact identity, and rollback relationship as Ash resources/actions while
preserving existing history and state-machine invariants.

## Slice 4.3 — Mutation actions and policies

Move deploy, cancel, retry, rollback, refresh, and declared-task requests behind
explicit Ash actions with operator policies, state validation, audit behavior,
and durable worker handoff.

## Slice 4.4 — Shared action surface

Remove migrated direct context calls from LiveViews and workers. The same Ash
actions must now serve:

- LiveView;
- internal workers;
- release/CLI entrypoints;
- later AshLua composition.

**Milestone exit:** all operator-visible core workflows use policy-protected Ash
actions; no AI-specific parallel business or infrastructure operation layer
exists.

---

# Milestone 5 — AshAI, AshLua, and MCP

**Goal:** let an authenticated user ask an agent to investigate and safely act by
composing the same Ash actions used by the web UI.

AshLua is the code-mode composition layer between Ash actions and AshAI. It is
not an arbitrary host scripting feature.

## Intended architecture

Follow the proven patterns in Jomat and ERP:

- an explicit agent-facing Ash domain;
- small projection/action resources that delegate to owning domains;
- `AshLua.EvalActions` over an explicit allow-list;
- one flat documentation tool and one flat evaluation tool;
- `AshAi.Mcp.Router` exposing only those two tools;
- host-supplied actor and authorization context that Lua cannot replace;
- bounded script, time, operation count, and encoded output;
- actionable, scrubbed errors and complete operation audit.

The external model-facing surface should remain approximately:

- `nixploy_lua_docs`
- `nixploy_lua_eval`

This avoids one large nested tool schema per Ash action and lets the model read
focused docs before composing several operations in one bounded Lua program.

Reference implementations and documentation:

- AshLua getting started and `AshLua.Docs` on HexDocs;
- `~/coding/jomat/lib/jomat/ai/tools.ex` for one shared docs/eval surface used by
  AshAI tool loops and MCP with actor/tenant context;
- `~/coding/sirkusagio/erp/lib/erp/agents/erp_lua.ex` for an explicit namespaced
  allow-list;
- `~/coding/sirkusagio/erp/lib/erp/agents/lua_eval.ex` for script, timeout,
  operation, output, transaction, and error bounds;
- ERP's prepare/execute confirmation and MCP audit patterns, adapted carefully
  for non-transactional infrastructure side effects.

## Slice 5.1 — Explicit read-only agent surface

Expose curated projections for:

- list managed workloads;
- get workload runtime/ingress details;
- fetch bounded logs;
- observe health;
- list deployments/events;
- compare declared input with observed runtime;
- explain available rollback candidates.

Exclude raw SQL, arbitrary modules/actions, environment values, secrets, host
configuration, generic Podman access, and shell execution.

## Slice 5.2 — Two-tool MCP tracer

**Observable behavior**

An authenticated tailnet operator connects an MCP client, asks for one
workload's failure evidence, and receives an answer composed from multiple
policy-protected read actions through AshLua.

**Acceptance criterion**

- MCP exposes only `nixploy_lua_docs` and `nixploy_lua_eval`.
- The server supplies the provisioned operator actor; Lua cannot select actor,
  authorization mode, resource module, or arbitrary action.
- Documentation supports capability index, search, and focused operation pages.
- Eval has strict body/script/time/operation/output bounds.
- The composed investigation uses real deployment, logs, health, and ingress
  actions and records an audit event.
- No mutation action is registered yet.

## Slice 5.3 — Diagnostic agent in the web UI

Use the same two-tool AshLua surface inside an AshAI tool loop to investigate a
selected workload. Keep prompts, progress, tool evidence, and final claims
bounded and auditable. The assistant must distinguish observed evidence from
inference and must not claim an operation succeeded without readback.

## Slice 5.4 — Confirmed mutation composition

Add deploy, rollback, restart, cancellation, and declared-task operations only
after their ordinary Ash actions are stable.

High-impact operations use a prepare/execute pattern:

- prepare returns exact consequences and a short-lived actor-bound reference;
- the user confirms in UI or MCP client;
- execute revalidates current state and consumes the confirmation once;
- durable operation state, idempotency, and independent readback determine
  success.

Unlike purely database-backed ERP actions, Podman/Caddy/Nix side effects cannot
be made atomic by wrapping Lua in a database transaction. nixploy must rely on
its persisted state machine, fencing, idempotent adapters, compensation, and
reconciliation rather than claiming transaction rollback of external effects.

## Slice 5.5 — Operational breadth and evaluation

- Add focused diagnostics for repeated crashes, health failures, ingress drift,
  failed deploys, and rollback choice.
- Test prompt injection through logs and application-controlled labels.
- Evaluate unauthorized requests, stale confirmations, concurrent mutations,
  timeouts, oversized output, partial external effects, and recovery.
- Run production-equivalent load and failure tests before describing the agent
  as an operational interface.

**Milestone exit:** UI and MCP agents compose the same policy-protected Ash
actions, read-only diagnosis is reliable, mutations require confirmation, and
all claims are backed by persisted events plus independent observations.

---

# Milestone 6 — Optional integrations after the local control plane

GitHub remains deliberately deferred until local deployment, rollback,
operations, mobile UI, self-host recovery, and the core Ash action model are
stable.

Potential later slices may include:

- GitHub App installation;
- repository metadata and webhook ingestion;
- immutable revision selection through GitHub;
- matching repository revisions to local Nix store inputs;
- deployment status checks.

These integrations may select or enrich immutable inputs. They must not become
the owner of application runtime configuration and must not make local operation
dependent on GitHub availability.

## Explicit non-goals

- managing arbitrary NixOS machine configuration from Phoenix;
- a public Phoenix listener that trusts Tailscale identity headers;
- arbitrary shell access from UI, Lua, MCP, or an LLM;
- mutating unmanaged containers, Caddy routes, or other host resources;
- storing decrypted project secrets in PostgreSQL;
- duplicating flake-owned application configuration in web forms;
- Kubernetes-style scheduling or general cluster orchestration;
- autonomous destructive operations without actor-bound confirmation;
- a big-bang Ash rewrite before the operational model is proven.

## Decision gates to resolve through tracers

The following remain decisions to prove, not abstractions to pre-build:

- operator-side transport for immutable Nix store sources;
- stable resource identity for a new project with no existing managed workload;
- worker credential handoff for SOPS/project secrets;
- persisted log/artifact storage and retention;
- exact web/worker split and lease granularity under real load;
- MCP authentication for non-browser clients while retaining the Tailscale
  network boundary;
- how existing Ecto tables migrate incrementally to Ash resources;
- which operations require prepare/execute confirmation versus ordinary audited
  execution.

## Immediate next step

Start **Slice 1.5 — Native production adoption** with one existing application
while the others remain available. Reuse its unchanged flake-owned credential
references and pre-start declarations, adopt only its positively identified
managed prefix, deploy and roll back through the native path, and retain the
compatibility adapter until public health and recovery evidence are documented.
