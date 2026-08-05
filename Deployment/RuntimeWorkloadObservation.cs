namespace Nixploy.Cli;

public sealed record RuntimeWorkloadObservation(
    string ContainerId,
    string ContainerName,
    string ImageReference,
    string ImageId,
    string State,
    string Status,
    string Project,
    string Target,
    string Repository,
    string Revision,
    string ConfigurationDigest,
    string OperationId,
    string ResourceKey,
    string? StartedAt,
    string? CpuPercent,
    string? MemoryUsage,
    string? MemoryPercent,
    string? Pids,
    string? NetworkIo,
    string? BlockIo
);
