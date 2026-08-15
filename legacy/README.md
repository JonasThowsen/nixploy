# Legacy implementation archive

This directory preserves retired nixploy implementations and historical rewrite
notes for compatibility research only. It is read-only reference material: do
not add features here or use it to shape the active OCaml architecture.

The active root flake does not package, check, import, or otherwise depend on
anything under `legacy/`. Production code lives under `ocaml/` and `nix/`.

- `phoenix/` contains the retired Elixir/Phoenix control plane.
- `csharp/` contains the original user-facing CLI used as capability-parity
  evidence.
- `moonbit/policy/` contains the retired deployment policy component.
- `docs/` contains historical implementation plans and tracers.

`config/dev.exs` remains temporarily at the repository root because it contains
pre-existing uncommitted user work. It is the sole legacy archive overlap and
must not be moved without explicit owner approval.
