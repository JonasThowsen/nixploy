# nixploy development direction

## Product statement

nixploy is a pragmatic way to deploy applications as containers built with Nix.
It is Kamal-like for Nix: every application should follow as uniform an operator lifecycle and runtime shape as practical.

A project flake declares an image and one or more deployment targets. nixploy builds that image, connects to Podman over SSH, installs referenced SOPS secrets, runs fixed pre-start commands, starts the application container, and optionally manages a Caddy blue/green route.

The original user-facing C# CLI on `main` is the capability reference for the OCaml rewrite. Parity means preserving its useful product behavior:

- `deploy` and `prune`;
- web and non-web targets;
- flake configuration for images, runtime argv, environment, network, ports, pre-start commands, typed read-only bind mounts, secrets, SSH, and Caddy;
- stable ownership of Podman connections, containers, secrets, and Caddy routes, with canonical identities bound to repository identity as well as project and target.

Parity does not mean copying old bugs. The OCaml implementation should retain explicit failures, bounded diagnostics, exact managed-resource verification, immutable revision support, safe cancellation, and verified compensation.

## Active and legacy scope

OCaml is the only active implementation direction. Both the CLI and Bonsai web control plane must use the same OCaml application API.

The following are legacy and must not influence new production design:

- Elixir/Phoenix, Ecto, PostgreSQL, Oban, split worker roles, and release registration;
- the MoonBit deployment policy;
- the expanded C# machine protocol created for Phoenix.

Legacy sources are archived under `legacy/` now that the OCaml API, package, and NixOS service no longer depend on them. They may be consulted for compatibility evidence but receive no new product features.

## Source policy

The application API represents source selection explicitly:

- the CLI may deploy the current local flake, matching the pragmatic C# workflow;
- the web UI deploys an explicitly previewed Git revision from an allowlisted repository.

Both policies resolve to one stable prepared deployment source before the shared deployment engine performs configuration evaluation, build, and remote mutation. Local preparation snapshots the repository's committed files, tracked modifications, and intent-to-add files once, while excluding ignored build output; evaluation, secrets, and image building all consume that same snapshot. Ordinary non-ignored untracked files fail preflight with an instruction to add or ignore them, avoiding both silently omitted source and copied dependency trees. Immutable preparation materializes exactly the selected full commit. Relative source inputs such as SOPS files resolve beneath that prepared root. Source selection is a caller policy; deployment semantics are shared.

Preview and any offline or read-only plan are operator advice, not mutation
authority. After confirmation, the application must acquire the declared
per-target coordination-domain lease and, while holding it, recompute or
revalidate the authoritative plan from fresh observations before any mutation.

## Architecture

```text
                         +------------------+
CLI parsing/rendering -->|                  |
                         |   Application    |--> Git/Nix adapter
RPC authorization ------>|      API         |--> Podman adapter
                         |                  |--> Caddy adapter
                         +------------------+--> SOPS adapter
                                  |
                                  +------------> SQLite operation store

Bonsai client <---- typed RPC declarations <---- RPC adapter
```

### Dependency direction

1. Pure domain modules define validated values and deployment decisions.
2. `Application` defines operator use cases and orchestrates capabilities.
3. Concrete adapters perform Git, Nix, process, Podman, Caddy, SOPS, filesystem, clock, and SQLite effects.
4. CLI and RPC are transport adapters over `Application`.
5. Bonsai consumes shared API values through RPC and contains no deployment semantics.

CLI and RPC code must not orchestrate lower-level adapters directly.

### OCaml module design

Follow these references:

- [Real World OCaml: Files, Modules, and Programs](https://dev.realworldocaml.org/files-modules-and-programs.html)
- [Real World OCaml: Functors](https://dev.realworldocaml.org/functors.html)
- [Real World OCaml: First-Class Modules](https://dev.realworldocaml.org/first-class-modules.html)
- [OCaml Programming Guidelines](https://ocaml.org/docs/guidelines)

Apply them as follows:

- Every production module has an explicit `.mli`.
- Use abstract types to control construction and preserve invariants.
- Expose variants when exhaustive pattern matching is part of the domain API.
- Keep pure decisions independent of Async and subprocesses.
- Represent expected failure with `Or_error.t` and `Deferred.Or_error.t`.
- Use one restrained application functor for compile-time dependency injection when useful.
- Avoid functor hierarchies, first-class modules, plugins, and generic framework abstractions without a demonstrated second implementation.
- Keep the safety-critical deployment and compensation sequence cohesive.

The repository-specific details are captured in `.agents/skills/ocaml-application-design/SKILL.md`.

## Shared application operations

The active application facade owns:

- source preview and resolution;
- deploy;
- prune;
- scoped status;
- lightweight deployment history and cancellation used by CLI and web;
- runtime logs and metrics only where they remain small direct observations.

Named operational tasks, release distribution, policy engines, generic remote commands, and queue-based orchestration are not active product scope. The bounded Production V1 lifecycle contract is defined in [`PRODUCTION_LIFECYCLE_V1.md`](PRODUCTION_LIFECYCLE_V1.md) and ordered in [`ROADMAP.md`](ROADMAP.md).

## Delivery plan

Each milestone is a production tracer with an observable acceptance criterion.

### 1. Shared application seam

Move existing source preview and tracked web deployment behind `Application`. CLI and RPC must call that facade without changing deployed behavior.

**Acceptance:** an application-service test substitutes fake capabilities and proves that the CLI main-preview policy and RPC explicit-revision policy pass the exact selected commit and callbacks. Focused consumer mapping tests cover CLI deployment output/terminal-state mapping and RPC operation-id extraction.

### 2. Non-web parity

Add a typed non-web plan to the shared engine. Run pre-start commands before replacing the single owned application container. Do not invoke Caddy.

**Acceptance:** a recorded command trace proves pre-start-before-replacement, exact runtime options, scoped ownership, verification, and no Caddy effects.

### 3. Prune parity

Add one scoped prune operation using the same resolved resource identity as deploy. Remove the owned route when configured, the single/blue/green container names, and owned secrets.

**Acceptance:** web and non-web command traces prove that unrelated resources cannot be selected.

### 4. Consumer cutover (complete)

CLI and web use only `Application`. Argument parsing, rendering, authorization, managed-application lookup, and serialization remain at their respective edges. `Application` owns live scoped status, scoped deployment history, process-local cancellation registration, bounded logs, bounded host/runtime/health metrics, runtime source resolution, and runtime caching. Cancellation requires the managed application identity plus operation id; persisted interrupted operations remain visible after restart but are honestly reported as not active in the new process.

The CLI exposes shared status and target-scoped history. RPC cancellation version 1 adds the application key while version 0 remains available only to return a safe upgrade error. Deploy and prune invalidate application-owned runtime observations.

**Acceptance:** direct adapter calls are absent from CLI/RPC handlers; application boundary tests cover status, history, cancellation ownership and restart behavior, logs, and metrics; CLI/RPC contract tests exercise the shared seam.

### 5. Packaging cutover (complete)

The default NixOS module is `services.nixploy`. It runs the packaged OCaml
`nixploy-web` executable as one loopback-only `nixploy.service`, with SQLite and
Podman client state under `/var/lib/nixploy`. The old
`services.nixploy-control-plane` namespace is only a rename alias; split roles,
PostgreSQL, Ecto, release registration, and backup behavior are not carried
forward. Legacy package outputs remained temporarily for a fenced rollback until
milestone 6 and have now been removed.

A NixOS VM check starts the production package, verifies health and unrestricted
UI access, checks the loopback listener and SQLite state, and performs a typed
`List_applications` RPC through a VM-only `rpc_probe`. That RPC traverses the
real RPC adapter, `Application` resource/history read, and SQLite store without
triggering a deployment or requiring a remote Podman host.

**Acceptance:** the NixOS module starts the packaged OCaml executable, serves
health/UI on loopback, and exposes the shared application API over typed RPC.

**Cutover fence:** stop every old Phoenix web/worker process before starting the
OCaml service and never overlap deployment engines. Preserve the long-lived
`nixploy` Unix identity, repositories, SSH/known-host credentials, and SOPS
identities. PostgreSQL history is not migrated; the OCaml service begins a new
SQLite history while retaining the established remote resource identities.

### 6. Legacy archive (complete)

C#, Phoenix, MoonBit, and historical implementation documents are preserved beneath `legacy/` as read-only references. Their packages, checks, dependencies, and development tools have been removed from the active root flake.

**Acceptance:** active root builds and tests contain only Nix configuration plus OCaml CLI/web; repository search finds no production dependency on `legacy/`.

## Testing

Run OCaml checks through Nix:

```bash
nix develop . -c dune runtest --root ocaml
nix develop . -c ./nix/test-mix-expo-source.sh
nix build .#nixploy
```

Protect pure domain rules with focused tests. At process boundaries, assert fixed argv, stdin, environment, output bounds, and compensation. For each tracer, exercise a packaged consumer rather than treating compilation as completion.

## Control-plane browser origin policy

Static control-plane HTTP requests use `NIXPLOY_AUTH_MODE` and, in Tailscale
mode, `NIXPLOY_OPERATOR_EMAIL`. WebSocket RPC upgrades use the same identity
check and also fail closed unless the browser supplies a valid `http` or
`https` `Origin`. By default that origin authority must equal the request
`Host`, preserving same-origin localhost development. Set
`NIXPLOY_ALLOWED_ORIGIN` at process startup when the exact public origin differs
from the forwarded host (for example `https://nixploy.example.com`). It accepts
one scheme-and-authority origin only; it does not accept userinfo, paths,
queries, fragments, wildcard or suffix matching. Scheme/host case and default
ports are normalized before exact comparison. Missing, `null`, malformed, or
mismatched origins are rejected in every auth mode, including Tailscale.

Origin validation does not establish a trusted-proxy boundary. Production V1
Tailscale mode must reject direct requests. The trusted proxy strips any
caller-supplied identity and injects only verified identity across an
authenticated or otherwise protected proxy-to-service boundary that direct
local clients cannot reach. A protected Unix socket is one possible boundary,
but an equivalent design is acceptable; loopback TCP alone is insufficient.

## Agent delivery

Repository agents commit and push completed task-owned changes automatically. They must protect unrelated work, stage explicit paths, avoid force-pushes, and report validation and commit receipts. See `.agents/skills/commit-and-push/SKILL.md`.
