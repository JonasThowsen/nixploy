using System.CommandLine;
using System.Security.Cryptography;
using System.Text;

namespace Nixploy.Cli;

public static class CommandFactory
{
    public static RootCommand CreateRootCommand(
        ICommandRunner commandRunner,
        INixployConfigProvider configProvider,
        IPodmanService podmanService,
        ISopsService sopsService,
        ICaddyService caddyService
    )
    {
        var targetOption = new Option<string>("--target", "-t")
        {
            Description = "Target server"
        };

        var deployCommand = new Command("deploy", "Build, load, and run an OCI image on a target server")
        {
            Options = { targetOption }
        };

        deployCommand.SetAction(async parseResult =>
        {
            var targetName = parseResult.GetValue(targetOption);

            if (string.IsNullOrWhiteSpace(targetName))
            {
                Console.Error.WriteLine("Missing required target. Pass one with --target <name>.");
                return;
            }

            NixployConfig config;

            try
            {
                config = await configProvider.GetConfigAsync();
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return;
            }

            if (!config.Targets.TryGetValue(targetName, out var target))
            {
                Console.Error.WriteLine($"Unknown target '{targetName}'.");

                if (config.Targets.Count > 0)
                {
                    Console.Error.WriteLine("Available targets:");

                    foreach (var availableTarget in config.Targets.Keys.Order())
                    {
                        Console.Error.WriteLine($"  {availableTarget}");
                    }
                }

                return;
            }

            if (string.IsNullOrWhiteSpace(target.Image))
            {
                Console.Error.WriteLine($"Target '{targetName}' is missing required image.");
                return;
            }

            DeploymentMetadata metadata;

            try
            {
                metadata = await CreateDeploymentMetadataAsync(config.Project, targetName, commandRunner);
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return;
            }

            var resourcePrefix = ResourcePrefix(metadata.Project, metadata.ProjectId, targetName);
            var podmanConnection = podmanService.GetConnectionName(resourcePrefix);
            const string imageOutputPath = "result-nixploy-image";

            Console.WriteLine($"Deployment identity: {resourcePrefix}");
            Console.WriteLine($"Git commit: {metadata.GitCommit}; deployed at: {metadata.DeployedAt}");

            if (!await podmanService.EnsureConnectionAsync(resourcePrefix, targetName, target))
            {
                return;
            }

            Console.WriteLine($"Building image '.#{target.Image}'...");

            CommandRunResult buildResult = await commandRunner.RunAsync(
                "nix",
                ["build", $".#{target.Image}", "-o", imageOutputPath]
            );

            if (buildResult.ExitCode != 0)
            {
                Console.Error.WriteLine($"Image build failed with exit code {buildResult.ExitCode}.");
                return;
            }

            IReadOnlyList<Secret> secrets;

            try
            {
                secrets = await sopsService.LoadSecretsAsync(target);
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return;
            }

            IReadOnlyList<SecretMount>? secretMounts = await podmanService.InstallSecretsAsync(
                podmanConnection,
                resourcePrefix,
                secrets
            );

            if (secretMounts is null)
            {
                return;
            }

            Console.WriteLine($"Loading image onto target '{targetName}' using Podman connection '{podmanConnection}'...");

            LoadedImage? loadedImage = await podmanService.LoadImageAsync(podmanConnection, imageOutputPath);

            if (loadedImage is null)
            {
                return;
            }

            if (target.Web is not null)
            {
                await DeployWebTargetAsync(
                    resourcePrefix,
                    targetName,
                    target,
                    podmanConnection,
                    loadedImage.Reference,
                    secretMounts,
                    metadata,
                    podmanService,
                    caddyService
                );

                return;
            }

            await DeploySimpleTargetAsync(
                resourcePrefix,
                targetName,
                target,
                podmanConnection,
                loadedImage.Reference,
                secretMounts,
                metadata,
                podmanService
            );
        });

        var pruneCommand = new Command("prune", "Remove nixploy resources for a project target")
        {
            Options = { targetOption }
        };

        pruneCommand.SetAction(async parseResult =>
        {
            var targetName = parseResult.GetValue(targetOption);

            if (string.IsNullOrWhiteSpace(targetName))
            {
                Console.Error.WriteLine("Missing required target. Pass one with --target <name>.");
                return;
            }

            NixployConfig config;

            try
            {
                config = await configProvider.GetConfigAsync();
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return;
            }

            if (!config.Targets.TryGetValue(targetName, out var target))
            {
                Console.Error.WriteLine($"Unknown target '{targetName}'.");
                return;
            }

            DeploymentMetadata metadata;

            try
            {
                metadata = await CreateDeploymentMetadataAsync(config.Project, targetName, commandRunner);
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return;
            }

            var resourcePrefix = ResourcePrefix(metadata.Project, metadata.ProjectId, targetName);
            var podmanConnection = podmanService.GetConnectionName(resourcePrefix);

            Console.WriteLine($"Pruning deployment identity: {resourcePrefix}");

            if (!await podmanService.EnsureConnectionAsync(resourcePrefix, targetName, target))
            {
                return;
            }

            if (target.Web is not null)
            {
                await caddyService.DeleteRouteAsync(resourcePrefix, target);
            }

            if (!await podmanService.PruneTargetAsync(podmanConnection, resourcePrefix))
            {
                return;
            }

            Console.WriteLine("Prune completed successfully.");
        });

        var root = new RootCommand("Nixploy")
        {
            Subcommands =
            {
                deployCommand,
                pruneCommand
            }
        };

        return root;
    }

    private static async Task DeployWebTargetAsync(
        string resourcePrefix,
        string targetName,
        NixployTarget target,
        string podmanConnection,
        string imageReference,
        IReadOnlyList<SecretMount> secretMounts,
        DeploymentMetadata metadata,
        IPodmanService podmanService,
        ICaddyService caddyService
    )
    {
        var activePort = await caddyService.GetActivePortAsync(resourcePrefix, target);
        // var slot = SelectSlot(target.Web!, activePort);
        var (slotName, slotPort) = SelectSlot(target.Web!, activePort);
        var newContainerName = $"{resourcePrefix}-{slotName}";
        var oldContainerName = activePort is null
            ? null
            : $"{resourcePrefix}-{(activePort == target.Web!.Slots.Blue ? "blue" : "green")}";

        Console.WriteLine(activePort is null
            ? $"No active Caddy upstream found. Starting {slotName} slot on port {slotPort}."
            : $"Active port is {activePort}. Starting {slotName} slot on port {slotPort}.");

        Console.WriteLine($"Removing legacy single-container deployment '{resourcePrefix}' if it exists...");
        await podmanService.StopContainerAsync(podmanConnection, resourcePrefix);

        if (!await podmanService.RunPreStartCommandsAsync(
                podmanConnection,
                imageReference,
                target.Run.PreStart,
                target.Run.Network,
                target.Run.Environment,
                slotPort,
                secretMounts,
                target.Run.ReadOnlyBinds
            ))
        {
            return;
        }

        Console.WriteLine($"Starting {slotName} container '{newContainerName}' from image '{imageReference}'...");

        await podmanService.StopContainerAsync(podmanConnection, newContainerName);

        if (!await podmanService.RunImageAsync(
                podmanConnection,
                newContainerName,
                imageReference,
                target.Run,
                slotPort,
                secretMounts,
                metadata
            ))
        {
            return;
        }

        if (!await caddyService.CheckHealthAsync(target, slotPort))
        {
            Console.Error.WriteLine("New slot failed health check. Leaving existing Caddy route unchanged.");
            return;
        }

        if (!await caddyService.SwitchAsync(resourcePrefix, target, slotPort))
        {
            Console.Error.WriteLine("New slot is healthy, but Caddy switch failed. Leaving new container running for inspection.");
            return;
        }

        if (!string.IsNullOrWhiteSpace(oldContainerName) && oldContainerName != newContainerName)
        {
            Console.WriteLine($"Stopping old container '{oldContainerName}'...");
            await podmanService.StopContainerAsync(podmanConnection, oldContainerName);
        }

        Console.WriteLine($"Deployment completed successfully. {target.Web!.Domain} now routes to {slotName} ({slotPort}).");
    }

    private static async Task DeploySimpleTargetAsync(
        string resourcePrefix,
        string targetName,
        NixployTarget target,
        string podmanConnection,
        string imageReference,
        IReadOnlyList<SecretMount> secretMounts,
        DeploymentMetadata metadata,
        IPodmanService podmanService
    )
    {
        var containerName = resourcePrefix;

        if (!await podmanService.RunPreStartCommandsAsync(
                podmanConnection,
                imageReference,
                target.Run.PreStart,
                target.Run.Network,
                target.Run.Environment,
                null,
                secretMounts,
                target.Run.ReadOnlyBinds
            ))
        {
            return;
        }

        Console.WriteLine($"Starting container '{containerName}' from image '{imageReference}'...");

        if (!await podmanService.RunImageAsync(
                podmanConnection,
                containerName,
                imageReference,
                target.Run,
                null,
                secretMounts,
                metadata
            ))
        {
            return;
        }

        Console.WriteLine("Deployment completed successfully.");
    }

    private static async Task<DeploymentMetadata> CreateDeploymentMetadataAsync(
        string project,
        string targetName,
        ICommandRunner commandRunner
    )
    {
        if (string.IsNullOrWhiteSpace(project))
        {
            throw new InvalidOperationException("nixploy project is required. Set `project = \"your-app\";` in nixploy.lib.makeConfig.");
        }

        var commit = await GitOutputAsync(commandRunner, ["rev-parse", "--short=12", "HEAD"]) ?? "unknown";
        var origin = await GitOutputAsync(commandRunner, ["config", "--get", "remote.origin.url"])
            ?? Directory.GetCurrentDirectory();
        var projectId = ShortHash(origin);
        var deployedAt = DateTimeOffset.UtcNow.ToString("O");

        return new DeploymentMetadata(project, projectId, targetName, commit, deployedAt);
    }

    private static async Task<string?> GitOutputAsync(ICommandRunner commandRunner, IReadOnlyList<string> arguments)
    {
        var result = await commandRunner.RunAsync(
            "git",
            arguments,
            new CommandRunOptions { StreamOutput = false }
        );

        return result.ExitCode == 0 && !string.IsNullOrWhiteSpace(result.StdOutput)
            ? result.StdOutput.Trim()
            : null;
    }

    private static string ResourcePrefix(string project, string projectId, string targetName)
    {
        return $"nixploy-{SanitizeName(project)}-{projectId}-{SanitizeName(targetName)}";
    }

    private static string ShortHash(string value)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes)[..10].ToLowerInvariant();
    }

    private static string SanitizeName(string value)
    {
        return string.Concat(value.Select(character =>
            char.IsLetterOrDigit(character) || character is '-' or '_'
                ? char.ToLowerInvariant(character)
                : '-'
        )).Trim('-');
    }

    private static (string Name, int Port) SelectSlot(NixployWebConfig web, int? activePort)
    {
        if (activePort == web.Slots.Blue)
        {
            return ("green", web.Slots.Green);
        }

        return ("blue", web.Slots.Blue);
    }
}
