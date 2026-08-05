namespace Nixploy.Cli;

public interface IPodmanService
{
    string GetConnectionName(string resourcePrefix);

    Task<bool> EnsureConnectionAsync(string resourcePrefix, string targetName, NixployTarget target);

    Task<LoadedImage?> LoadImageAsync(string connectionName, string imagePath);

    Task<IReadOnlyList<SecretMount>?> InstallSecretsAsync(
        string connectionName,
        string resourcePrefix,
        IReadOnlyList<Secret> secrets
    );

    Task<bool> RunPreStartCommandsAsync(
        string connectionName,
        string imageReference,
        IReadOnlyList<IReadOnlyList<string>> commands,
        string? network,
        IReadOnlyDictionary<string, string> environment,
        int? port,
        IReadOnlyList<SecretMount> secrets
    );

    Task<bool> RunImageAsync(
        string connectionName,
        string containerName,
        string imageReference,
        NixployRunConfig runConfig,
        int? port,
        IReadOnlyList<SecretMount> secrets,
        DeploymentMetadata metadata
    );

    Task<VerifiedContainer?> VerifyContainerAsync(
        string connectionName,
        string containerName,
        string imageReference,
        DeploymentMetadata metadata
    );

    Task StopContainerAsync(string connectionName, string containerName);

    Task<bool> PruneTargetAsync(string connectionName, string resourcePrefix);
}
