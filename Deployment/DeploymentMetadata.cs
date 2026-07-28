namespace Nixploy.Cli;

public sealed record DeploymentMetadata(
    string Project,
    string ProjectId,
    string Target,
    string Repository,
    string GitCommit,
    string DeployedAt
);
