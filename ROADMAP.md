# nixploy roadmap

The product contract is [DEVELOPMENT.md](DEVELOPMENT.md): a daemonless deployment
CLI with a small application runbook. This replaces the control-plane roadmap.

## 1. Establish the smaller product contract — complete

Record the CLI-only direction, the initial running-container runbook contract,
and the safety properties that survive removal of centralized authority. Retire
conflicting development instructions. This is a documentation milestone only.

## 2. Make the packaged product CLI-only — next

- Remove browser/RPC routing from CLI commands and make direct deployment the
  sole application path.
- Remove web/server/protocol code, service-only application APIs, managed authority
  and custody machinery, and dashboard observers. Preserve necessary deployment
  state and ownership checks rather than deleting all shared code by association.
- Remove Bonsai, JavaScript, web/RPC packaging dependencies, web assets, service
  package outputs, and the Nixploy NixOS service module and its service-only tests.
- Simplify flake configuration so an ordinary declared deployment target needs
  neither managed registration nor a production/nonProduction authority profile.
  Diagnose obsolete control-plane configuration rather than silently ignoring it.
- Provide migration instructions for existing service installations, state, and
  configuration. Preserve running container names, labels, secrets, and routes.
- Resolve overlapping mutation protection without a persistent Nixploy broker;
  test independent clients, crashes, conflicts, and uncertain remote outcomes.

**Acceptance:** the packaged CLI deploys both a non-web and a Caddy-backed test
application from a checkout without any Nixploy service or `/etc/nixploy` registry.
Tests prove ownership, source consistency, secret handling, rollback, and
coordination. The package and dev shell no longer build a web UI or RPC service.

## 3. Deliver the running-container runbook

Implement the configuration and execution contract in
[DEVELOPMENT.md](DEVELOPMENT.md#runbook-first-slice), through the CLI, application
operation, active-container resolution, and Podman exec boundaries.

**Acceptance:** a packaged CLI lists commands and executes a named command in the
verified running container without a build, deployment, or new container. Tests
cover non-web and active blue/green selection, missing/foreign/ambiguous resources,
literal argv, separate streamed output, nonzero exit status, interactive terminal
behavior, concurrent deployment, and no replay after transport failure. Exercise
one non-interactive command and one console against a designated test application.

## 4. Finish the small operator surface

- Expose bounded CLI logs and useful scoped status/history without dashboard
  caches or background polling services.
- Add stable structured output, documented exit codes, and agent-friendly examples.
- Re-enable prune only with explicit destructive scope, ownership verification,
  concurrency protection, and honest partial-failure reporting. It is currently
  disabled; removing the old receipt architecture is not permission to bypass it.
- Trim leftover abstractions and update all user documentation to demonstrated
  behavior, not planned capabilities.

**Acceptance:** a human and a non-interactive script can deploy, inspect, operate,
and safely clean up a test application using only the packaged CLI and its help.

## Deliberately deferred

One-off runbook containers and parameterized commands need a concrete use case
before implementation. Web UI, RPC, Nixploy daemons, application registries,
schedulers, queues, generic workflow engines, and server provisioning are outside
the product boundary, not backlog items.
