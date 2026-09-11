---
name: ocaml-application-design
description: Design, implement, refactor, and review the daemonless nixploy OCaml CLI using intentional interfaces, validated types, pure domain decisions, and Async effect boundaries. Use for every OCaml source, test, Dune, CLI, runbook, deployment, Podman, Caddy, SOPS, Nix packaging, architecture, or control-plane removal change in this repository.
compatibility: nixploy repository; Nix development shell; OCaml 5.2, Dune, Core, Async
---

# OCaml application design for nixploy

## Product boundary

Follow the daemonless CLI product and runbook contract in `DEVELOPMENT.md` and
the removal sequence in `ROADMAP.md`. Keep the working deployment engine while
subtracting control-plane infrastructure. Code under `legacy/` is compatibility
evidence, not an active dependency or a template for a new rewrite.

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

Keep deployment and runbook orchestration behind application-level operations.
The CLI is the sole consumer; additional transports are not a design requirement.

The intended dependency direction is:

```text
pure domain -> Application -> adapters
                    ^
                   CLI
```

CLI modules parse arguments, call `Application`, render results, and select exit
codes. Keep Git, Nix, Podman, Caddy, SOPS, and Store orchestration out of parsing
and rendering code.

### Parameterize only real effects

Use one restrained application functor when compile-time dependency injection materially improves tests:

```ocaml
module Make (Runtime : Runtime.S) : Application.S
```

Group concrete effect modules behind `Runtime.S` when using that functor; keep
domain types outside it so CLI, tests, and adapters share them without type-sharing
gymnastics. Do not introduce this seam solely for a hypothetical second frontend.

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
- Preserve mutation coordination when removing the daemon; local locks alone do not coordinate independent operator machines.
- Runbook commands select a positively owned running container by ID, use literal argv, and are never retried automatically after an uncertain failure.

## Tracer workflow

For each slice:

1. Name one operator-visible behavior and its acceptance criterion.
2. Add or update the application API first.
3. Implement the smallest complete domain-to-adapter path.
4. Exercise it through the packaged CLI rather than only isolated layers.
5. Add focused pure tests and one boundary/integration test.
6. Run the repository checks in the Nix development shell.
7. Track deferred work in `ROADMAP.md`, not speculative abstractions.

## Validation

Before completing an OCaml change, run the relevant subset and normally all of:

```bash
nix develop . -c dune runtest --root ocaml
nix build .#nixploy
```

For command-surface changes, run the packaged executable and inspect help/output.
For deployment and runbook command construction, assert ordered argv, ownership,
stream/exit behavior, and important failure compensation with fakes. Remove
web-only tests with web code, not the deployment safety tests it shared.

Read and follow `.agents/skills/commit-and-push/SKILL.md` for delivery.
