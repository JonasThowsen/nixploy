---
name: commit-and-push
description: Deliver completed nixploy repository changes by validating them, committing only task-owned files, and pushing the current branch without waiting for an explicit user request. Use this skill for every task that creates, edits, moves, or deletes repository files, including delegated agent work. It must trigger whenever an agent is about to finish a mutation task in this repository.
compatibility: Git repository with an origin remote and authenticated push access
---

# Commit and push nixploy changes

The repository owner has authorized agents working in nixploy to commit and push completed changes without asking again. Treat delivery as part of the definition of done.

## Protect existing work

At the start of a mutation task, record:

```bash
git status --short --branch
git branch --show-current
git remote -v
```

Pre-existing changes belong to the user or another task. Do not edit, stage, revert, stash, move, or commit them unless the current task explicitly owns those exact files. If a required edit overlaps an unrelated pre-existing change and cannot be preserved confidently, stop and report the conflict.

Never use destructive cleanup, `git reset --hard`, `git checkout --`, or `git clean` on work you did not create.

## Commit logical milestones

Commit a coherent, validated milestone rather than every small edit or one enormous unrelated batch.

Before committing:

1. Inspect `git diff --check`.
2. Inspect the task-owned diff.
3. Run the relevant tests/builds from project instructions.
4. Confirm no secrets, generated build products, editor files, or unrelated changes are included.
5. Stage explicit task-owned paths with `git add -- <path>...`.
6. Inspect `git diff --cached --stat` and `git diff --cached`.

Do not use `git add -A`, `git add .`, or broad path staging when unrelated work exists.

Use a concise conventional commit subject that states the behavior, for example:

```text
feat(ocaml): add shared deployment application API
fix(ocaml): scope status to the selected resource key
docs: define the OCaml application architecture
chore: archive legacy control-plane sources
```

If hooks modify files, inspect and restage only task-owned results, rerun affected validation, and amend or make a follow-up commit as appropriate.

## Push automatically

After a successful commit, push the current checked-out branch:

```bash
git push
```

If the branch has no upstream, use:

```bash
git push --set-upstream origin HEAD
```

Never force-push, delete remote branches, rewrite published history, or bypass hooks. Do not silently switch branches. A normal non-fast-forward rejection is a coordination issue: report it rather than rebasing or merging unrelated remote work automatically.

Push each completed logical milestone before handing work back when practical. If later review requires a fix, commit and push the fix separately.

## Handoff

Report:

- commit SHA and subject;
- pushed branch and remote;
- validation commands and outcomes;
- any task-owned changes intentionally left uncommitted;
- unrelated pre-existing changes still present.

A mutation task is not complete until the commit is pushed or a concrete push failure is reported.
