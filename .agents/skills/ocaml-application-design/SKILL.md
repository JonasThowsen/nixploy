---
name: ocaml-application-design
description: Design, implement, refactor, and review OCaml in nixploy using idiomatic modules, signatures, abstract invariant-bearing types, pure domain decisions, Async effect boundaries, and one shared application API for CLI and web. Use this skill for every OCaml source, test, Dune, CLI, RPC, Bonsai-server, deployment, Podman, Caddy, SOPS, or architecture change in this repository, even when the request does not explicitly mention OCaml style.
compatibility: nixploy repository; Nix development shell; OCaml 5.2, Dune, Core, Async
---

# OCaml application design for nixploy

## Product boundary

Keep nixploy a pragmatic tool for deploying Nix-built application containers.

The active OCaml product owns:

- evaluating project flake deployment configuration;
- building the selected Nix image;
- deploying it to Podman over SSH;
- SOPS dotenv secrets and fixed pre-start commands;
- non-web replacement and Caddy blue/green deployment;
- scoped status and prune operations;
- a small SQLite operation history where it serves CLI and web.

Do not extend active OCaml code with Phoenix, PostgreSQL, Oban, MoonBit policy, release registration, general workflow orchestration, or plugin architecture. Code under `legacy/` is reference material, not an active dependency.

For parity questions, treat the original user-facing C# CLI on Git `main` as the capability reference: `deploy`, `prune`, web and non-web targets, configuration, resource ownership, Podman, SOPS, pre-start commands, and Caddy. Preserve deliberate OCaml safety improvements rather than copying old bugs or unsafe failure behavior.

## Required reading

Before architectural work, read:

- `DEVELOPMENT.md`
- `ocaml/README.md`
- the relevant `.mli` files before their `.ml` implementations

Use these external design references when a module boundary is uncertain:

- Real World OCaml, Files, Modules, and Programs: https://dev.realworldocaml.org/files-modules-and-programs.html
- Real World OCaml, Functors: https://dev.realworldocaml.org/functors.html
- Real World OCaml, First-Class Modules: https://dev.realworldocaml.org/first-class-modules.html
- OCaml Programming Guidelines: https://ocaml.org/docs/guidelines

## Design rules

### Make interfaces intentional

Give every production module an explicit `.mli`. Start from the interface when adding or materially changing a module. Expose the smallest useful API.

Use abstract `type t` for values whose construction must preserve invariants, including identifiers, requests, configuration, runtime ownership, and successful outcomes. Provide validating constructors and explicit accessors.

Expose a concrete variant when clients genuinely need exhaustive pattern matching over domain states. Do not hide variants merely to add getters for constructors.

Keep large-scope public names descriptive. Avoid exposing representation-specific helpers.

### Put the domain before effects

Represent deployment choices with pure functions and typed values before invoking Async effects. Examples include:

- resource identity;
- target kind (`Non_web` or `Web`);
- candidate slot selection;
- owned resource names;
- deployment/prune plans;
- state and stage transitions.

Test these decisions without subprocesses.

Keep expected failures in `Or_error.t` or `Deferred.Or_error.t`. Reserve exceptions for programmer errors and impossible invariant violations. Bound diagnostic text and never retain secrets.

### Use one application facade

CLI and web must call the same application-level operations. They may differ in transport, authorization, rendering, and source-selection policy, but not in deployment or prune orchestration.

The intended dependency direction is:

```text
pure domain -> Application -> adapters
                    ^
                 CLI/RPC
```

CLI modules parse arguments, call `Application`, render results, and select exit codes. RPC handlers authorize, call `Application`, and serialize shared API values. Neither surface may orchestrate Git, Nix, Podman, Caddy, SOPS, or Store directly.

### Parameterize only real effects

Use one restrained application functor when compile-time dependency injection materially improves tests:

```ocaml
module Make (Runtime : Runtime.S) : Application.S
```

Group concrete effect modules behind `Runtime.S`; keep domain types outside the functor so CLI, RPC, tests, and adapters share them without type-sharing gymnastics.

Do not create chains of tiny functors. Do not use first-class modules unless runtime selection among heterogeneous implementations is a demonstrated requirement. A record of closures is acceptable for a small capability with no associated types.

### Keep Async at the boundary

Use `Deferred.Or_error.t` for application and adapter operations. Avoid Async in pure domain modules. Do not block the Async scheduler with synchronous process or filesystem work.

Pass cancellation and stage observation explicitly through application requests or runtime capabilities. Do not make CLI signals the application API.

### Preserve ownership and safety

- Never use a shell to construct deployment commands.
- Keep argv fixed and typed as string lists.
- Verify managed labels and exact resource identity before mutation.
- Scope prune to names derived from the same identity used by deploy.
- Pass secrets through stdin or private environment/file mechanisms, never argv.
- Preserve strict SSH host-key verification.
- Keep output, time, line, and byte bounds explicit.
- Prefer verified compensation over reproducing legacy failure quirks.

## Tracer workflow

For each slice:

1. Name one operator-visible behavior and its acceptance criterion.
2. Add or update the application API first.
3. Implement the smallest complete domain-to-adapter path.
4. Exercise it through a real consumer (CLI or RPC) rather than only isolated layers.
5. Add focused pure tests and one boundary/integration test.
6. Run the repository checks in the Nix development shell.
7. Leave broader deferred behavior in `DEVELOPMENT.md`, not speculative abstractions.

The first parity slices are:

1. shared `Application` facade around existing deploy behavior;
2. non-web deployment;
3. scoped prune;
4. CLI and web migration to the facade;
5. OCaml NixOS service cutover.

## Validation

Before completing an OCaml change, run the relevant subset and normally all of:

```bash
nix develop . -c dune runtest --root ocaml
nix build .#nixploy
```

For command-surface changes, run the packaged executable and inspect help/output. For RPC changes, run focused RPC tests. For deployment command construction, assert ordered argv and important failure compensation with fakes.

Read and follow `.agents/skills/commit-and-push/SKILL.md` for delivery.
