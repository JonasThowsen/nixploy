# Native local deployment tracer design

## Observable behavior

An operator submits an already-immutable Nix store source through a local
handoff. nixploy derives the target configuration from that source's flake,
starts the inactive rootless Podman slot, checks the exact declared health path,
and switches the existing Caddy route only after the candidate is healthy.
Deployment progress and failure remain visible in the existing history.

## Concrete acceptance criterion

For one no-secret production-style fixture:

1. The request persists a verified `/nix/store/...` source path and its NAR hash
   before execution.
2. `.#nixploy` is evaluated from that exact store path. No repository, target,
   service, domain, port, or health-path form is introduced.
3. A single existing managed project/target identity is adopted from positive
   `io.nixploy.*` or legacy labels; ambiguity and unmanaged name collisions fail
   closed.
4. Caddy's current upstream is read before mutation, and only the inactive slot
   declared by the flake is replaced in the `nixploy` user's Podman store.
5. The built image identity and candidate container identity are recorded. The
   exact flake-declared health URL must return 2xx within a bounded retry window.
6. Caddy's identified reverse-proxy upstream is patched only after health
   succeeds. A failed build, start, health check, or switch is recorded, and the
   previously routed healthy slot is not stopped or removed.
7. The deployed-style test observes persisted stage events, the new Caddy
   upstream after success, and the unchanged old upstream after injected
   failure.

The legacy adapter remains available until this complete path succeeds and a
rollback operation has been exercised.

## Findings from the current implementation

The C# adapter's safe sequence is concentrated in
`Commands/CommandFactory.cs` and `Services/Caddy/CaddyService.cs`:

- inspect the identified Caddy proxy and fail closed if its state is unavailable;
- select the opposite blue/green port from flake configuration;
- run pre-start commands, replace only the inactive container, and start it;
- retry the exact flake health path before changing ingress;
- patch only the identified proxy upstream;
- leave the active route unchanged when candidate health fails.

The current Elixir worker already provides durable transitions, bounded output,
cancellation checks, target leases, and final independent verification. Its
Git checkout, registered-service config comparison, and `LegacyExecutor` call
are the boundaries to replace for local input—not abstractions to duplicate.

Production also revealed two constraints:

- Existing Jomat and Salgsoversikt containers have legacy project/target labels
  and stable resource prefixes, but no repository-source label. Initial native
  adoption must therefore match project and target labels and require one
  unambiguous managed prefix.
- Both applications require encrypted project secrets and pre-start commands.
  They are not safe first candidates until a credential handoff is designed.
  The first native tracer must use a no-secret fixture while preserving both
  production applications.

## Chosen local input boundary

The immutable input is a Nix store source path staged by an operator-side local
handoff (initially a release task; later a thin authenticated CLI/API). Before a
job is queued, nixploy will run bounded `nix path-info --json -- <path>`, require
an existing source path under `/nix/store`, and persist the returned NAR hash.
Retries use only that path and hash.

The worker will evaluate and build with fixed arguments equivalent to:

```text
nix eval --json --no-write-lock-file <store-path>#nixploy
nix build --json --no-link <store-path>#<image-output>
```

The normalized target is the sole application configuration input. The database
stores the immutable source identity, derived normalized snapshot/digest,
operation state, observations, and audit history—not editable copies of flake
fields.

## Native local execution stages

1. **Select input** — verify and persist store path plus NAR hash.
2. **Derive config** — evaluate schema `v0.2`, select one target, and persist a
   canonical digest of the derived target.
3. **Adopt identity** — discover one positively managed local prefix matching
   project/target labels and inspect its Caddy proxy.
4. **Build/load** — build the flake image output and load it into local Podman as
   `nixploy`; record the resulting image ID.
5. **Prepare inactive slot** — refuse unmanaged collisions, replace only the
   inactive managed container, and start it with flake-derived argv, environment,
   network, and port rendering.
6. **Verify candidate** — inspect its image/state/labels and retry the exact
   loopback health URL with fixed bounds.
7. **Switch ingress** — patch only the adopted Caddy proxy upstream, then verify
   Caddy and public health independently before success.

Every external process uses `Nixploy.Execution.Command` with fixed argument
vectors, explicit timeout, bounded output, cancellation checks, and no shell
interpolation.

## Deliberately deferred boundaries

- `TODO(tracer)` in `Nixploy.Deployments.Source`: dispatch local-store inputs
  without teaching the Git adapter about them.
- `TODO(tracer)` in `Nixploy.Deployments.Worker`: select a native executor only
  for persisted local-store inputs while retaining `LegacyExecutor` rollback.
- Secret and pre-start support: reject non-empty declarations in the first
  fixture; add a credential-reference handoff before adopting Jomat or
  Salgsoversikt.
- New-project resource identity: first adopt one existing managed prefix;
  require a flake-derived stable identity before creating a project from
  nothing.
- Operator-side store-path transport, rollback UI, inactive-slot retention, and
  garbage collection follow only after the first native switch is proven.
- GitHub installation, metadata, webhooks, and revision selection remain out of
  scope.

## Completed staging increment

Slice 1.1 now persists and validates one local-store input plus its derived flake
target and canonical configuration digest, then renders those immutable values
in operation history and a stable mobile-safe detail route. The real Nix store
and evaluator boundary is covered by a no-secret fixture. Staging records actor,
state, failure, timestamps, and audit evidence without creating legacy
repository, target, or service rows, enqueueing a worker, or invoking either
deployment adapter.

## Completed native blue/green increment

Slice 1.2 now persists native operations and append-only stages, serializes an
active project/target operation in PostgreSQL, re-verifies the staged source and
digest, builds with bounded machine-readable Nix output, loads and identifies
the image in rootless Podman, refuses unmanaged collisions, mutates only the
inactive managed slot, retries the exact health path, and creates or patches
only the derived Caddy route/proxy IDs after health. Success requires Caddy,
container, image, labels, and health readback.

The packaged production exercise used input
`eb552f49-a3a7-4f0f-95e5-ccb7ad3a4472`. Operation
`076100f1-49f3-47fe-8e9d-17353d46cdf4` established the isolated blue fixture;
operation `d851af15-a71d-4046-a4e7-d1e83156b32e` then selected green as the
inactive slot, switched the proxy to `127.0.0.1:18081`, and stopped blue. The
fixture's direct and Caddy-routed `/health` responses both returned 2xx.

The source closure was copied manually with unprivileged `nix copy` to
`nixploy@nixploy`. Productized operator transport remains a deliberate future
boundary; no root application operation or production application input was
used.

## Next smallest implementation slice

Inject native build, start, health, and Caddy-switch failures while asserting
the old upstream remains selected, then add rollback as a new audited operation
referencing an exact prior store path, NAR hash, image identity, configuration
digest, and slot. Project secrets/pre-start actions and adoption of existing
production applications remain explicitly deferred.
