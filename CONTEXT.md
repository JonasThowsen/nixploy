# Nixploy context

## Glossary

- **Control plane** — The single trusted service that admits, records, observes, and executes managed deployment operations.
- **Operator client** — A CLI or browser UI that requests an operation from the control plane and renders its result; it does not directly mutate a managed target.
- **Managed application** — An allowlisted application identity whose repository, target, and resource scope are owned by the control plane.
- **Deployment target** — The remote Linux host and Podman/Caddy runtime that receives an application's workload. A target is not the control-plane host.
- **Deployment operation** — The durable, target-scoped lifecycle record from admission through terminal result or explicit review.
- **Target observation** — A timestamped, bounded report of deployment-target host and runtime health. It is separate from a deployment operation.
