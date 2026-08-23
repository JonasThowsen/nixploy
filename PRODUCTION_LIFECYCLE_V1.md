# Production lifecycle V1 contract

This document bounds the next production milestone. Nixploy is Kamal-like for
Nix: project flakes keep application intent, while Nixploy gives applications as
uniform an operator lifecycle and runtime shape as practical. The canonical
shape is **preview → advisory plan → confirm → lease → authoritative
revalidation/plan → prepare → start → ready → switch/replace → verify → retire →
record**, with explicit compensation and reconciliation. An offline or read-only
plan informs the operator but cannot authorize later mutation. The authoritative
plan is recomputed or revalidated from fresh observations while holding the
declared per-target coordination-domain lease before any mutation.

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for architecture and
[`ROADMAP.md`](ROADMAP.md) for dependency order and completed UI receipts.

## Canonical operator journeys

`Complete` means the repository has the documented capability receipt. It does
not exempt that behavior from the V1 gates below. `Partial` means a useful path
exists but a named V1 safety property is absent.

| # | Operator journey | Current status | Production V1 observable outcome |
|---|---|---|---|
| 1 | Preview the exact immutable source before acting | Implemented tracer | The UI-proven commit comes from root-protected Git custody with a bounded fresh root-owned provenance/ref/object manifest, then is immutably materialized and evaluated. Mutable Git origin text is not authority and stable ownership is represented separately. A bounded process-local single-use receipt binds the root-managed application, source evidence, target, production destination, canonical resource identity policy, coordination scope, exact SHA, and configuration digest. Expiry, eviction, replay, mismatch, or restart requires a new preview; revalidation inside the target lease fails before resource/history writes or remote/secret effects. |
| 2 | Review an advisory read-only deploy, prune, or rollback plan | Missing | Without remote mutation, the operator sees proposed owned-resource changes, prerequisites, readiness and availability effects, and reasoned rollback candidates. The advice cannot authorize mutation and may change after fresh under-lease observation. |
| 3 | Deploy a web application and preserve its healthy route | Partial | A candidate uses one lifecycle, becomes ready, switches the exact owned route, is independently verified, and retires the prior slot; failure leaves or restores the last known-good route. |
| 4 | Deploy a non-web application without false availability claims | Partial | Readiness is explicit. Advisory and authoritative plans plus the outcome state whether replacement is continuous or has a bounded interruption; no Caddy behavior is implied. |
| 5 | Observe and control one operation | Complete | Status, history, stages, bounded logs and metrics remain honest; cancellation is scoped and reaches a terminal result only after compensation. |
| 6 | Prune only one configured application's exact resources | Partial | Prune is derived from the selected managed application's exact repository identity and target, fails closed on ownership ambiguity, and cannot select a colliding checkout or retained writable data. |
| 7 | Recover safely after control-plane or host interruption | Missing | Before new mutation, persisted intent is reconciled with observed containers, routes, secret generations, and lease ownership; ambiguity blocks rather than guesses. |
| 8 | Rotate application secrets without a destructive gap | Missing | A complete candidate generation is installed and verified before cutover; failure preserves the last known-good generation and leaves bounded cleanup evidence. |
| 9 | Roll back to a known eligible deployment | Missing | The operator can select only a retained, previously successful immutable revision whose required artifacts and secret generation are available; Nixploy verifies the rollback like a deploy. |
| 10 | Reuse required writable application data safely | Missing | A typed existing host path is preflighted before mutation and retained across deploy, rollback, and prune. Nixploy never creates, migrates, backs up, restores, or deletes it. |

## Ownership boundary

| Boundary | Owns in V1 | Does not own |
|---|---|---|
| **Nixploy core** | Exact source/identity binding; advisory read-only plans; authoritative under-lease deploy, rollback, and exact prune decisions; per-target coordination-domain leases; crash reconciliation; transactional Podman secret generations; web and non-web readiness/verification; typed preflight of retained existing writable paths; recording and surfacing bounded operator-supplied external backup/egress evidence references. | Application startup choreography, arbitrary commands, databases, backup execution, evidence-reference verification or attestation, egress enforcement, or host-wide policy. |
| **Project flake and application** | Image, fixed argv/environment, declared pre-start commands, ports, readiness intent, secrets references, typed mounts, and application-specific compatibility/runbooks. | Mutating Nixploy's ownership rules or silently weakening host prerequisites. |
| **NixOS and external operations** | Podman/Caddy/SSH/SOPS host setup, trusted reverse-proxy identity handoff, credential custody, immutable backup and restore testing, egress enforcement, monitoring, supplying bounded evidence references, and maintenance coordination through the declared per-target coordination domain. | Implicitly authorizing Nixploy to take over ambiguous state. |

Sirkus Agio is the demanding acceptance fixture, not a source of one-off core
abstractions. Its ordered gateway → ERP rollout remains a Sirkus runbook and
application-compatibility concern until a second application proves a generic
Nixploy need. Immutable external backup and egress controls are activation
prerequisites. Nixploy records and surfaces a bounded operator-supplied external
backup/egress evidence reference; it neither verifies nor attests the referenced
mechanism and does not implement either mechanism.

## Dependency-ordered gates

### P0 — lifecycle safety

0. **Safety corrections**
   - Prune resolves the exact allowlisted repository, subdirectory, project, and
     target used by the managed application and fails closed on any mismatch.
   - In Tailscale mode, direct requests are rejected. The trusted proxy strips
     caller-supplied identity and injects only verified identity across an
     authenticated or otherwise protected proxy-to-service boundary that direct
     local clients cannot reach. A protected Unix socket or equivalent may
     provide that boundary; loopback TCP alone is insufficient.
   - Preview authorization verifies root-protected Git custody plus a fresh
     root-owned provenance/ref/object manifest, then separately binds application,
     stable ownership identity, target, exact source, production destination,
     canonical resource identity policy, coordination scope, and evaluated
     configuration digest server-side. CLI and web read one root-owned machine
     authority; local snapshots on a managed host require an exact non-production
     contract and cannot alias a protected production domain. Confirmation
     supplies only the opaque receipt. Missing, expired, evicted, replayed, restarted, mismatched, or
     conflicting state can only force re-preview, never fall through to
     mutation. Receipt freshness has no lease or takeover semantics.
   - **Evidence:** packaged negative-path staging checks demonstrate all three
     failures without target mutation.

1. **Advisory read-only lifecycle plan and rollback eligibility**
   - Advisory output identifies proposed additions, replacements, switches,
     retirements, and removals plus readiness, interruption, retained-data,
     operator-supplied backup/egress evidence references, and lease
     prerequisites.
   - Rollback advice names candidate immutable revisions or an actionable reason
     none appears available.
   - Offline or read-only advice cannot authorize later mutation and is not
     represented as the exact plan that will execute.
   - **Evidence:** repeated advisory planning is mutation-free and deterministic
     for the same prepared source and observations.

2. **Per-target coordination-domain lease and authoritative revalidation**
   - After operator confirmation, deploy, rollback, prune, and reconciliation
     acquire the declared per-target coordination-domain lease. While holding
     it, Nixploy recomputes or revalidates the authoritative plan from fresh
     observations before any mutation.
   - Only actors that declare the same durable coordination domain serialize.
     Unrelated targets co-hosted on one machine do not take a host-global lock;
     external backup or maintenance can participate by declaring the same
     target domain without Nixploy implementing those jobs.
   - The current `Store` flock is local per SQLite path and cannot be shared with
     external actors, so it does not yet satisfy this gate.
    - Loss of lease ownership or an apparently stale owner never permits
      automatic unsafe takeover; observed state must first be reconciled or an
      operator must make an explicit, evidenced recovery decision.
    - **Evidence:** packaged contention and interrupted-owner staging scenarios
      admit one actor in a declared domain and leave its competitors read-only
      and clearly blocked, while an unrelated co-hosted target remains
      independent. The packaged target-lease VM additionally proves a
      generation-scoped dirty/clean-receipt protocol that survives broker
      interruption as blocked state, fails closed on corrupt, partial,
      mismatched, or ambiguous durable evidence, treats durability faults as
      process-fatal within one select-loop cycle, bounds connection saturation,
      and keeps accept floods from starving an existing holder. Strict crash
      fencing remains blocked until every remote mutating process is
      broker-supervised or independent recovery proves stopped orphans.

3. **Crash reconciliation**
   - Startup and pre-mutation reconciliation compare persisted intent with exact
     observed resources and secret generations. It produces a safe terminal
     result, bounded compensation, or an explicit blocked state.
   - **Evidence:** kill the packaged service at each mutation boundary, restart
     it, and show that no duplicate switch, destructive cleanup, or unexplained
     success occurs.

4. **Transactional secret generations**
   - Candidate names are generation-scoped; all required values are prepared
     before workload cutover. Retirement occurs only after verified success.
   - **Evidence:** injected failures during prepare, start, switch, and retire
     preserve a runnable last known-good generation and disclose cleanup state
     without secret values.

5. **Non-web readiness and availability**
   - The application declares a bounded readiness observation suitable for its
     runtime. Nixploy does not report success before it passes.
   - If a singleton replacement cannot preserve availability, plan and outcome
     say so instead of pretending to provide blue/green semantics.
   - **Evidence:** staged success, timeout, cancellation, and failed replacement
     traces agree with observed process availability and compensation.

6. **Narrow immutable rollback**
   - Rollback is a constrained deployment of one eligible prior recorded
     revision, not an arbitrary ref, command, or general release bundle.
   - **Evidence:** staging returns from a newer revision to the exact eligible
     prior revision, verifies it, and rejects missing or ineligible artifacts
     before mutation.

### P1 — retained state and fixture proof

7. **Typed retained existing writable data**
   - The schema exposes only the narrow path contract proven necessary. The
     remote path must already exist and pass type, access, and conflict checks.
   - It is mounted only where declared and is excluded from every prune and
     compensation selector.
   - **Evidence:** staging preserves marker data through deploy, failed deploy,
     rollback, and prune; missing or unsafe paths fail before mutation.

8. **Sirkus Agio offline/staging acceptance**
   - Produce a reviewable offline preview and advisory plan, then exercise the
     packaged V1 lifecycle against an isolated Sirkus staging target. Include
     failure and rollback drills, retained-data proof, lease contention, crash
     recovery, secret generation switching, and bounded operator-supplied
     external backup/egress evidence references. Nixploy records and surfaces
     those references without verifying or attesting the external mechanisms.
   - Record exact package revision, application revision, target observations,
     commands/checks, and outcomes. Production activation is explicitly outside
     this milestone.

P1 is required for V1 completion and begins only after P0. No Production V1
gate is production-proven until both its packaged path and staged evidence
exist.

## Tracer contract

Every implementation slice must name these fields before work begins:

- **User value:** the operator outcome improved.
- **Question:** the risky product or architecture assumption being tested.
- **Smallest journey:** one packaged end-to-end path through the real boundary.
- **Deferred:** adjacent behavior intentionally not generalized yet.
- **Evidence:** observable success and important failure receipts retained from
  staging.

## Explicit non-goals

Production V1 does **not** add a generic release bundle, workflow or policy
engine, arbitrary hooks or exec, database or accessory provisioner, multi-host
roles, provider/accounting/legal semantics, automatic backup implementation,
production activation, or a generic host firewall manager. A second real
application—not speculation—is required before promoting Sirkus-specific
coordination into Nixploy core.
