# nixploy agent instructions

nixploy is a pragmatic OCaml application for deploying Nix-built containers. The original user-facing C# CLI on `main` is the capability-parity reference; Elixir/Phoenix and MoonBit are legacy and must not shape new production architecture.

Before changing OCaml, Dune, CLI, RPC, web-server, deployment, Podman, Caddy, SOPS, or Nix packaging code, read and follow:

- `.agents/skills/ocaml-application-design/SKILL.md`
- `DEVELOPMENT.md`

For every task that mutates repository files, read and follow:

- `.agents/skills/commit-and-push/SKILL.md`

Agents are authorized to commit task-owned changes and push the current branch without asking again. Never include unrelated pre-existing work. In particular, inspect the initial Git status and stage explicit paths only.

Run project commands through the repository Nix development shell unless already inside it.
