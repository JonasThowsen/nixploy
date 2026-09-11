# nixploy agent instructions

nixploy is a daemonless OCaml CLI for deploying Nix-built applications to remote Podman servers and running named commands inside their running containers. `DEVELOPMENT.md` is the authoritative product contract; `ROADMAP.md` tracks the CLI-only cutover. Historical control-plane plans are superseded. The original user-facing C# CLI under `legacy/` is compatibility evidence, not the architectural template.

Before changing OCaml, Dune, CLI, runbook, deployment, Podman, Caddy, SOPS, or Nix packaging code, or removing control-plane code, read and follow:

- `.agents/skills/ocaml-application-design/SKILL.md`
- `DEVELOPMENT.md`

For every task that mutates repository files, read and follow:

- `.agents/skills/commit-and-push/SKILL.md`

Agents are authorized to commit task-owned changes and push the current branch without asking again. Never include unrelated pre-existing work. In particular, inspect the initial Git status and stage explicit paths only.

Run project commands through the repository Nix development shell unless already inside it.
