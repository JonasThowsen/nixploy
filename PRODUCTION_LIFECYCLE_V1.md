# Production lifecycle V1 contract

This document bounds the next production milestone. Nixploy is Kamal-like for
Nix: project flakes keep application intent, while Nixploy gives applications as
uniform an operator lifecycle and runtime shape as practical. The canonical
shape is **preview → plan → lease → prepare → start → ready → switch/replace →
verify → retire → record**, with explicit compensation and reconciliation.

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for architecture and
[`ROADMAP.md`](ROADMAP.md) for dependency order and completed UI receipts.

## Canonical operator journeys

`Complete` means the repository has the documented capability receipt. It does
not exempt that behavior from the V1 gates below. `Partial` means a useful path
exists but a named V1 safety property is absent.

| # | Operator journey | Current status | Production V1 observable outcome |
|---|---|---|---|
| 1 | Preview the exact immutable source before acting | Complete | The application, repository, target, commit, and evaluated intent shown to the operator remain bound to the later plan and mutation. Expiry, eviction, restart, or cache failure requires a new preview. |
| 2 | Review a read-only deploy, prune, or rollback plan | Missing | Without remote mutation, the operator sees exact owned-resource changes, prerequisites, readiness and availability effects, and a reasoned rollback eligibility result. |
| 3 | Deploy a web application and preserve its healthy route | Partial | A candidate uses one lifecycle, becomes ready, switches the exact owned route, is independently verified, and retires the prior slot; failure leaves or restores the last known-good route. |
| 4 | Deploy a non-web application without false availability claims | Partial | Readiness is explicit. The plan and outcome state whether replacement is continuous or has a bounded interruption; no Caddy behavior is implied. |
| 5 | Observe and control one operation | Complete | Status, history, stages, bounded logs and metrics remain honest; cancellation is scoped and reaches a terminal result only after compensation. |
| 6 | Prune only one configured application's exact resources | Partial | Prune is derived from the selected managed application's exact repository identity and target, fails closed on ownership ambiguity, and cannot select a colliding checkout or retained writable data. |
| 7 | Recover safely after control-plane or host interruption | Missing | Before new mutation, persisted intent is reconciled with observed containers, routes, secret generations, and lease ownership; ambiguity blocks rather than guesses. |
| 8 | Rotate application secrets without a destructive gap | Missing | A complete candidate generation is installed and verified before cutover; failure preserves the last known-good generation and leaves bounded cleanup evidence. |
| 9 | Roll back to a known eligible deployment | Missing | The operator can select only a retained, previously successful immutable revision whose required artifacts and secret generation are available; Nixploy verifies the rollback like a deploy. |
| 10 | Reuse required writable application data safely | Missing | A typed existing host path is preflighted before mutation and retained across deploy, rollback, and prune. Nixploy never creates, migrates, backs up, restores, or deletes it. |

## Ownership boundary

| Boundary | Owns in V1 | Does not own |
|---|---|---|
| **Nixploy core** | Exact source/identity binding; read-only plans; deploy, rollback, and exact prune decisions; target-host mutation leases; crash reconciliation; transactional Podman secret generations; web and non-web readiness/verification; typed preflight of retained existing writable paths; recording and surfacing prerequisite evidence. | Application startup choreography, arbitrary commands, databases, backup execution, egress enforcement, or host-wide policy. |
| **Project flake and application** | Image, fixed argv/environment, declared pre-start commands, ports, readiness intent, secrets references, typed mounts, and application-specific compatibility/runbooks. | Mutating Nixploy's ownership rules or silently weakening host prerequisites. |
| **NixOS and external operations** | Podman/Caddy/SSH/SOPS host setup, trusted reverse-proxy identity handoff, credential custody, immutable backup and restore-test evidence, egress enforcement, monitoring, and maintenance coordination through the shared lease boundary. | Implicitly authorizing Nixploy to take over ambiguous state. |

Sirkus Agio is the demanding acceptance fixture, not a source of one-off core
abstractions. Its ordered gateway → ERP rollout remains a Sirkus runbook and
application-compatibility concern until a second application proves a generic
Nixploy need. Immutable external backup evidence and egress enforcement are
activation prerequisites whose presence Nixploy surfaces or attests; Nixploy
does not implement either mechanism.

## Dependency-ordered gates

### P0 — lifecycle safety

0. **Safety corrections**
   - Prune resolves the exact allowlisted repository, subdirectory, project, and
     target used by the managed application and fails closed on any mismatch.
   - Proxy-derived identity is accepted only through the configured trusted
     handoff; direct or spoofable identity headers cannot authenticate an
     operator.
   - Preview authorization binds exact source and evaluated intent. Missing,
     stale, evicted, or conflicting cache state can only force re-preview, never
     fall through to mutation.
   - **Evidence:** packaged negative-path staging checks demonstrate all three
     failures without target mutation.

1. **Read-only lifecycle plan and rollback eligibility**
   - Plan output identifies exact additions, replacements, switches,
     retirements, and removals plus readiness, interruption, retained-data,
     backup-evidence, egress, and lease prerequisites.
   - Rollback eligibility names the immutable candidate or an actionable reason
     it is unavailable.
   - **Evidence:** repeated planning is mutation-free and deterministic for the
     same prepared source and observations.

2. **Target-host mutation lease**
   - Deploy, rollback, prune, and reconciliation exclude concurrent mutation at
     the target-host boundary. External backup and maintenance can participate
     in the same narrow lease protocol without Nixploy implementing those jobs.
   - Loss, expiry, or an apparently stale owner never permits automatic unsafe
     takeover; observed state must first be reconciled or an operator must make
     an explicit, evidenced recovery decision.
   - **Evidence:** packaged contention and interrupted-owner staging scenarios
     admit one actor and leave all others read-only and clearly blocked.

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
   - Produce a reviewable offline preview/plan, then exercise the packaged V1
     lifecycle against an isolated Sirkus staging target. Include failure and
     rollback drills, retained-data proof, lease contention, crash recovery,
     secret generation switching, and externally supplied immutable-backup and
     egress-enforcement attestations.
   - Record exact package revision, application revision, target observations,
     commands/checks, and outcomes. Production activation is explicitly outside
     this milestone.

P1 is required for V1 completion and begins only after P0. No feature is
production-proven until both the packaged path and staged evidence exist.

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
