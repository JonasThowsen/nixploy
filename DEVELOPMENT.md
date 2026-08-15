# nixploy development direction

## Product statement

nixploy is a pragmatic way to deploy applications as containers built with Nix.

A project flake declares an image and one or more deployment targets. nixploy builds that image, connects to Podman over SSH, installs referenced SOPS secrets, runs fixed pre-start commands, starts the application container, and optionally manages a Caddy blue/green route.

The original user-facing C# CLI on `main` is the capability reference for the OCaml rewrite. Parity means preserving its useful product behavior:

- `deploy` and `prune`;
- web and non-web targets;
- flake configuration for images, runtime argv, environment, network, ports, pre-start commands, secrets, SSH, and Caddy;
- stable ownership of Podman connections, containers, secrets, and Caddy routes.

Parity does not mean copying old bugs. The OCaml implementation should retain explicit failures, bounded diagnostics, exact managed-resource verification, immutable revision support, safe cancellation, and verified compensation.

## Active and legacy scope

OCaml is the only active implementation direction. Both the CLI and Bonsai web control plane must use the same OCaml application API.

The following are legacy and must not influence new production design:

- Elixir/Phoenix, Ecto, PostgreSQL, Oban, split worker roles, and release registration;
- the MoonBit deployment policy;
- the expanded C# machine protocol created for Phoenix.

Legacy sources will move under `legacy/` after the OCaml API, package, and NixOS service no longer depend on them. They may be consulted for compatibility evidence but receive no new product features.

## Source policy

The application API represents source selection explicitly:

- the CLI may deploy the current local flake, matching the pragmatic C# workflow;
- the web UI deploys an explicitly previewed Git revision from an allowlisted repository.

Both policies resolve to the same prepared deployment source before the shared deployment engine performs configuration evaluation, build, and remote mutation. Source selection is a caller policy; deployment semantics are shared.

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

Named operational tasks, release distribution, policy engines, generic remote commands, and queue-based orchestration are not active product scope.

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

### 4. Consumer cutover (in progress)

Make CLI and web use only `Application`. Keep argument parsing, rendering, authorization, and serialization at their respective edges. CLI and web deploy and scoped prune now use the shared `Application` operations; remaining runtime observation cutover stays within this milestone.

**Acceptance:** direct adapter calls disappear from CLI/RPC handlers, and contract tests exercise the same application behavior through both surfaces.

### 5. Packaging cutover

Replace the Phoenix-oriented NixOS service with the OCaml `nixploy-web` service and SQLite state. Keep one service unless a real operational constraint demonstrates a split.

**Acceptance:** the NixOS module starts the packaged OCaml executable, serves health/UI on loopback, and deploys through the shared application API.

### 6. Legacy archive

Move C#, Phoenix, MoonBit, and historical implementation documents beneath `legacy/`. Remove their packages, checks, dependencies, and development tools from the active root flake.

**Acceptance:** active root builds and tests contain only Nix configuration plus OCaml CLI/web; repository search finds no production dependency on `legacy/`.

## Testing

Run OCaml checks through Nix:

```bash
nix develop . -c dune runtest --root ocaml
nix build .#nixploy
```

Protect pure domain rules with focused tests. At process boundaries, assert fixed argv, stdin, environment, output bounds, and compensation. For each tracer, exercise a packaged consumer rather than treating compilation as completion.

## Agent delivery

Repository agents commit and push completed task-owned changes automatically. They must protect unrelated work, stage explicit paths, avoid force-pushes, and report validation and commit receipts. See `.agents/skills/commit-and-push/SKILL.md`.
