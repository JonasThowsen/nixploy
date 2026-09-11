# Nixploy context

Nixploy concerns deploying applications and operating their running workloads.

## Language

**Application**:
The software being deployed, with its image and runtime requirements.
_Avoid_: Managed application, registered application

**Deployment target**:
A named destination and runtime configuration for an application, such as staging
or production. Different targets may share a remote server.

**Operator**:
The human or automation explicitly invoking a deployment or operational command.
_Avoid_: Operator client

**Deployment**:
An attempt to replace a target's running application with a selected build,
including preparation, verification, and any necessary failure recovery.

**Deployment request**:
An operator's selection of one application source and target for a deployment
attempt, not permission granted by a central application registry.

**Prepared source**:
The consistent application snapshot used for a deployment's configuration, image
build, and secret references.

**Active container**:
The running container currently serving the selected application's target. For a
blue/green web application, it is the slot receiving application traffic.

**Runbook**:
A target's collection of named, described operational commands.

**Runbook command**:
An operator-invoked command executed inside the target's active container.
_Avoid_: Workflow, job, task

**Pre-start command**:
An automatic deployment step run before the application starts, such as a
migration. It is distinct from an operator-invoked runbook command.

**Owned resource**:
A remote resource positively identified as belonging to an application's target,
rather than merely resembling one of its resource names.

**Resource identity**:
The repository, project, and target identity that distinguishes an application's
resources from other deployments, including ones sharing a server.

**Mutation guard**:
Exclusive coordination of deployments, cleanup, and runbook execution for a target,
with retained evidence when the outcome cannot safely be treated as complete.
_Avoid_: Expiring lease, automatic takeover

**Uncertainty evidence**:
A record that an operation's remote effects require reconciliation before another
mutation is allowed; it is not proof that the operation is still running.

**Local history**:
The operator machine's record of deployment attempts, not authority over remote
resources or proof of their current health.

**Legacy secret**:
An existing secret without sufficient ownership evidence for automatic replacement
or removal, even if its name resembles a target's secret name.
