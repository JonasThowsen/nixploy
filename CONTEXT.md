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
