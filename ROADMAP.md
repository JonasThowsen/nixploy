# nixploy product roadmap

## Product boundary

nixploy is a small, self-hosted deployment control plane for applications whose
deployment configuration lives in project flakes. The OCaml CLI and Bonsai web
UI share the same deployment engine and SQLite operation store.

The five completed UI tracers below make essential operator evidence easier to
understand and use. They are receipts, not a permanent limit on lifecycle work.
The remaining bounded scope is the dependency-ordered Production V1 contract in
[`PRODUCTION_LIFECYCLE_V1.md`](PRODUCTION_LIFECYCLE_V1.md); it does not reopen
generic control-plane expansion.

## Product principles

### Project flakes remain authoritative

The UI reads application intent from NixOS-allowlisted local repositories. It
must not introduce forms for editing repository, target, service, domain, port,
health, or secret configuration.

### The interface is an operator tool

The UI prioritizes legibility, current state, evidence, and useful actions. It is
not a consumer landing page and should not spend space or attention on decorative
content. Interactive controls, failures, stale data, and command progress must be
obvious.

Every capability must be equally usable on mobile and desktop. Desktop may show
more information side by side, but it must not have actions or evidence that are
unavailable on mobile. Detailed interaction and visual guidance lives in
[`UI_DIRECTION.md`](UI_DIRECTION.md).

### Implementation quality is a feature

New work should improve or preserve the quality of the OCaml codebase:

- follow the established Core, Async, Async RPC, and Bonsai idioms;
- use small modules with explicit interfaces and invariant-bearing types;
- represent domain states with typed variants instead of string conventions;
- keep pure decisions separate from Async effects where practical;
- model expected failures explicitly and keep diagnostic output bounded;
- share behavior between the CLI and UI instead of duplicating deployment logic;
- avoid abstractions until a real use demonstrates the seam;
- add focused tests for domain behavior and realistic checks for RPC, process,
  Podman, and browser boundaries;
- leave the repository easier to understand than before the change.

### State must be honest

The UI renders persisted operations and observed runtime facts. It must
distinguish running, succeeded, failed, cancelled, unavailable, and stale state
without inferring success from an optimistic client transition.

## Production baseline

The current OCaml path has been exercised against Jomat production and provides:

- exact local `refs/heads/main` resolution and immutable Nix image builds;
- remote rootless Podman deployment with stable workload identity;
- SOPS secrets and fixed-argument pre-start commands;
- blue/green health verification, Caddy switching, independent readback, and
  retirement of the previous slot;
- deployment compensation and safe process interruption;
- SQLite operations, stage events, outcomes, and local target leases;
- an authenticated Bonsai UI backed by the same tracked deployment function as
  the CLI;
- Tailscale-mode identity checks and a NixOS-packaged production service, with
  the protected trusted-proxy boundary still a P0 gate.

## Completed UI delivery receipts

Each completed item was delivered as a small end-to-end tracer: usable in the
packaged browser UI at both a narrow mobile viewport and desktop, covered by
focused tests, and exercised against real runtime data.

### 1. Commit preview

**Status: Implemented for source-and-intent binding.** Source metadata is previewed
before confirmation and the exact commit is immutably materialized and evaluated.
The server verifies a root-protected Git custody repository and bounded fresh
root-owned manifest that binds the configured provenance identifier, full ref,
and exact commit object; mutable Git origin configuration is not authority and
stable resource ownership never overwrites observed evidence. It validates
project, target, production destination, canonical resource identity policy,
coordination scope, and configuration digest, then retains them behind an opaque
single-use bounded-memory receipt. Confirmation supplies no SHA, target, or
destination; expiry, eviction, replay, mismatch, or restart requires a new
preview. Inside the target lease, deployment revalidates and prepares the full
intent before resource-state/history writes and before remote or secret effects.
The packaged VM proves exact production preview, forged receipt rejection, and
standalone-CLI rejection of tracked production changes, stanza removal, and
endpoint aliases with zero deployment/resource rows. Focused tests cover stale
or mismatched source evidence, provenance, SHA, target, destination and digest
mismatch before Podman/SSH, while receipt tests cover expiry, eviction, replay,
restart and application mismatch.
The receipt is preview freshness only, not the still-missing lifecycle lease or
authoritative fresh remote plan.

**Operator behavior:** Before deploying, an operator sees which commit from the
application's local `refs/heads/main` will be deployed.

Show at least the full commit SHA, short SHA, commit subject, and commit time in a
compact confirmation surface. The deployment must use the exact SHA shown in the
confirmation, even if `main` advances before the operator confirms.

**Acceptance:** Advance `main` after opening the confirmation, deploy, and verify
that the recorded and running revision is the commit that was shown rather than
the newer ref.

### 2. Recent deployments

**Status:** implemented. The SQLite v2 migration preserves v1 history and adds
application identity, commit metadata, start/finish timing, cancellation facts,
and a cancelled terminal state. The UI provides global and per-application
recent views with live elapsed time and useful failures.

**Operator behavior:** An operator can scan the latest deployments across all
allowlisted applications and inspect recent deployments for one application.

Each entry shows application, state, commit identity, start time, duration or
live elapsed time, current or terminal stage, and the most useful failure text.
The view has clear loading, empty, unavailable, and stale states. Long commit and
error text must not cause page-level horizontal scrolling.

**Acceptance:** From both mobile and desktop, identify the latest successful,
failed, and active deployment and open enough detail to understand its stage or
failure without querying SQLite manually.

### 3. UI cancellation

**Status:** implemented. Operation-scoped cancellation interrupts only the
selected process group, retains the target lease through cleanup, and records
`cancelled` only after a clean unwind. A packaged RPC deployment against Jomat
was cancelled during a real bounded command and reached terminal `cancelled`;
public health remained available.

**Operator behavior:** An operator can cancel an active deployment and follow it
to a terminal cancelled state.

Cancellation is cooperative, uses the existing process-group interruption and
compensation behavior, and disables duplicate requests. The UI explains that
cancellation may take time while cleanup runs. A cancelled operation is distinct
from a failed operation in storage and in the UI.

**Acceptance:** Cancel a deployment during a real bounded command, verify that
the command is interrupted, candidate side effects are compensated, the previous
healthy application remains routed, and the operation becomes `cancelled`.

### 4. Searchable application logs

**Status:** implemented. Logs are read by immutable ID from the positively
identified Caddy-active container, bounded to the latest 500 lines and 64 KiB,
and defensively redact common credential shapes. The packaged browser loaded
Jomat logs and passed search, match highlighting, pause/resume, refresh, mobile,
and desktop checks.

**Operator behavior:** An operator can open an application's recent logs, follow
new output, pause following, and search the loaded log window.

The first implementation reads a bounded recent window from the positively
identified running container. Search is literal, responsive, highlights matches,
shows a match count, and supports moving between matches. Operators can refresh
after a runtime error without losing the page. Log lines preserve timestamps and
stream identity when Podman provides them.

The viewer must handle long unbroken lines, keyboard navigation, touch controls,
and narrow screens without causing page-level overflow. Secret values must never
be deliberately persisted or added to diagnostics.

**Acceptance:** On a phone-sized viewport and desktop, load a bounded real
container log, search for a known value, move between matches, pause and resume
following, and recover from a failed log request.

### 5. Host and application metrics

**Status:** implemented. Fixed remote probes report host CPU, memory, filesystem,
load, and uptime; Podman and Caddy observations report per-application health,
CPU, memory, host-memory share, and uptime. A packaged live probe verified these
values against Jomat's remote target.

**Operator behavior:** An operator can judge whether each application target host
is healthy and see how much of it each managed application currently uses.

Host facts include CPU usage, memory usage and capacity, filesystem usage and
capacity, load, and uptime. Per-application facts include observed health, CPU
usage, memory usage, memory share of host, and container uptime. Values show when
they were observed and become visibly stale when refreshes stop. Measurements
come from the positively identified remote deployment target, not implicitly
from the machine running the control plane.

Prefer direct bounded host and Podman observations over introducing a separate
metrics stack. Historical retention and alerting are not part of this slice.

**Acceptance:** Compare target-host capacity with every running managed
application on mobile and desktop, distinguish healthy, unhealthy, unavailable,
and stale observations, and verify the displayed values against the remote host
and Podman source commands.

## Production V1 delivery order

This order is dependency-bearing; later work must not bypass an earlier gate.
The detailed journeys, ownership boundaries, exclusions, and evidence contract
live in [`PRODUCTION_LIFECYCLE_V1.md`](PRODUCTION_LIFECYCLE_V1.md).

0. **P0 — Safety corrections (partial):** make prune repository-exact; reject
   direct requests in Tailscale mode and fail closed at the protected
   trusted-proxy/auth boundary. Server-side preview binding for the application,
   protected source custody, repository provenance and separately represented
   ownership, target, exact source, production destination, and evaluated intent
   is complete. The shared root-owned CLI/web authority prevents local production
   downgrade or alias bypasses; no stale or fallback preview authorizes mutation.
1. **P0 — Advisory read-only lifecycle plan and rollback eligibility
   (missing):** show proposed changes, prerequisites, availability effect, and
   candidate prior immutable revisions without mutation. The offline/read-only
   result is operator advice only and cannot authorize later mutation.
2. **P0 — Per-target coordination-domain lease and authoritative revalidation
   (partial):** after confirmation, acquire the declared lease and recompute or
   revalidate the authoritative plan from fresh observations while holding it
   before mutation. The current `Store` flock is local per SQLite path and is not
   externally shareable. Only actors declaring the same durable domain
   serialize; unrelated targets co-hosted on one machine do not take a
   host-global lock. An ambiguous or stale owner must never permit unsafe
   takeover.

    **Tracer status: packaged broker journey implemented; lifecycle integration
    remains missing.** `services.nixploy.targetLease` installs a dedicated
    unprivileged Unix-socket broker with root-owned fixed authority, scope, and
    Unix-user allowlists; configured or connecting peers that resolve to UID 0
    are rejected during Nix evaluation and at admission. Durable ownership uses
    a generation-scoped dirty-marker plus clean-receipt protocol: releases make
    clean evidence independently durable before retiring the matching dirty
    marker, and any durability fault is process-fatal in the same select-loop
    cycle. Its packaged VM receipt proves peer-credential admission,
    same-scope contention, independent scopes, clean release, lease survival of
    broker interruption as durable blocked state, fail-closed startup on
    corrupt/partial/mismatched/ambiguous evidence, bounded connection-cap
    saturation and slot recovery, accept-flood fairness for an existing holder,
    and root-peer config rejection at evaluation time. The broker does not yet
    participate in `Application` deploy/prune/reconciliation, clear blocked
    state (operator-only), transport over SSH, supervise mutations, or claim
    strict crash fencing.
3. **P0 — Crash reconciliation (missing):** reconcile persisted intent with
   observed Podman, Caddy, secret, and lease state before another mutation.
4. **P0 — Transactional secret generations (missing):** prepare, switch, verify,
   and retire secret generations without destroying the last known-good set on
   failure.
5. **P0 — Non-web readiness and availability (partial):** add an explicit
   readiness gate and report the real availability consequence of replacement.
6. **P0 — Narrow immutable rollback (missing):** allow rollback only to an
   eligible, previously successful immutable deployment and verify the result.
7. **P1 — Retained existing writable data (missing):** permit only a typed,
   safely preflighted existing host path; Nixploy never creates, migrates,
   backs up, restores, or prunes it.
8. **P1 — Sirkus Agio offline/staging acceptance (missing):** exercise the
   packaged lifecycle against the demanding fixture without production
   activation and retain the evidence.

P1 remains required for Production V1; it follows the P0 safety foundation
rather than weakening it. The Jomat receipts above remain evidence for their
delivered behavior, but no Production V1 gate is production-proven until its
packaged path has staged evidence.

## Quality gates

Every UI slice must pass:

1. `dune runtest --root ocaml` in the repository's Nix development environment.
2. `nix build .#nixploy`.
3. Focused RPC and domain tests for the new behavior and its important failure
   case.
4. A real narrow-browser review with no page-level horizontal overflow and no
   hover-only action.
5. A desktop-browser review for useful density, keyboard access, visible focus,
   and readable operational state.
6. A packaged, production-style check against real SQLite and Podman data.

Implementation is not complete merely because the individual layers compile.
