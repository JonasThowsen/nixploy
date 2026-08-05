using System.CommandLine;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Text.Json;

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

        var sourceOption = new Option<string>("--source")
        {
            Description = "Exact immutable Nix source store path"
        };
        var gitRevisionOption = new Option<string>("--git-revision")
        {
            Description = "Persisted full Git commit"
        };
        var repositoryIdentityOption = new Option<string>("--repository-identity")
        {
            Description = "Operator-safe repository identity"
        };
        var configurationDigestOption = new Option<string>("--configuration-digest")
        {
            Description = "Persisted normalized configuration SHA-256 digest"
        };
        var operationIdOption = new Option<string>("--operation-id")
        {
            Description = "Durable deployment operation UUID"
        };
        var resourceKeyOption = new Option<string>("--resource-key")
        {
            Description = "Canonical host-computed managed resource key"
        };
        var eventsOption = new Option<string>("--events")
        {
            Description = "Machine event protocol; supported value: jsonl"
        };

        var deployCommand = new Command("deploy", "Build, load, and run an OCI image on a target server")
        {
            Options =
            {
                targetOption,
                sourceOption,
                gitRevisionOption,
                repositoryIdentityOption,
                configurationDigestOption,
                operationIdOption,
                resourceKeyOption,
                eventsOption
            }
        };

        deployCommand.SetAction(async parseResult =>
        {
            var targetName = parseResult.GetValue(targetOption);
            var immutable = ImmutableInvocation.Parse(
                parseResult.GetValue(sourceOption),
                parseResult.GetValue(gitRevisionOption),
                parseResult.GetValue(repositoryIdentityOption),
                parseResult.GetValue(configurationDigestOption),
                parseResult.GetValue(operationIdOption),
                parseResult.GetValue(resourceKeyOption)
            );

            if (!immutable.Success)
            {
                Console.Error.WriteLine(immutable.Error);
                return 1;
            }

            using var reporter = DeploymentReporter.Create(
                parseResult.GetValue(eventsOption),
                immutable.OperationId!
            );
            if (string.IsNullOrWhiteSpace(targetName))
            {
                Console.Error.WriteLine("Missing required target. Pass one with --target <name>.");
                return 1;
            }

            NixployConfig config;

            try
            {
                config = await configProvider.GetConfigAsync(immutable.Source!);
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return 1;
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

                return 1;
            }

            if (string.IsNullOrWhiteSpace(target.Image))
            {
                Console.Error.WriteLine($"Target '{targetName}' is missing required image.");
                return 1;
            }

            DeploymentMetadata metadata;

            try
            {
                metadata = CreateDeploymentMetadata(
                    config.Project,
                    targetName,
                    immutable.RepositoryIdentity!,
                    immutable.GitRevision!
                ) with
                {
                    ConfigurationDigest = immutable.ConfigurationDigest!,
                    OperationId = immutable.OperationId!,
                    ResourceKey = immutable.ResourceKey!
                };
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return 1;
            }

            var resourcePrefix = ResourcePrefix(metadata.Project, targetName);
            if (!string.Equals(resourcePrefix, immutable.ResourceKey, StringComparison.Ordinal))
            {
                Console.Error.WriteLine("Canonical resource key does not match the immutable deployment input.");
                return 1;
            }

            var podmanConnection = podmanService.GetConnectionName(resourcePrefix);
            const string imageOutputPath = "result-nixploy-image";

            Console.WriteLine($"Deployment identity: {resourcePrefix}");
            Console.WriteLine($"Git commit: {metadata.GitCommit}; deployed at: {metadata.DeployedAt}");

            if (!await podmanService.EnsureConnectionAsync(resourcePrefix, targetName, target))
            {
                return 1;
            }

            Console.WriteLine($"Building image '{immutable.Source}#{target.Image}'...");
            reporter.Stage("building", "Building the exact immutable image output");

            CommandRunResult buildResult = await commandRunner.RunAsync(
                "nix",
                [
                    "build",
                    "--no-update-lock-file",
                    "--no-write-lock-file",
                    $"{immutable.Source}#{target.Image}",
                    "-o",
                    imageOutputPath
                ]
            );

            if (buildResult.ExitCode != 0)
            {
                Console.Error.WriteLine($"Image build failed with exit code {buildResult.ExitCode}.");
                return 1;
            }

            IReadOnlyList<Secret> secrets;
            reporter.Stage("installing_credentials", "Resolving worker-only credential references");

            try
            {
                secrets = await sopsService.LoadSecretsAsync(target);
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return 1;
            }

            IReadOnlyList<SecretMount>? secretMounts = await podmanService.InstallSecretsAsync(
                podmanConnection,
                resourcePrefix,
                secrets
            );

            if (secretMounts is null)
            {
                return 1;
            }

            Console.WriteLine($"Loading image onto target '{targetName}' using Podman connection '{podmanConnection}'...");

            LoadedImage? loadedImage = await podmanService.LoadImageAsync(podmanConnection, imageOutputPath);

            if (loadedImage is null)
            {
                return 1;
            }

            reporter.Stage(
                "loading",
                "Loaded the built image and read back its immutable identity",
                new Dictionary<string, object?>
                {
                    ["image_reference"] = loadedImage.Reference,
                    ["image_id"] = loadedImage.Id
                }
            );

            if (target.Web is not null)
            {
                var deployed = await DeployWebTargetAsync(
                    resourcePrefix,
                    targetName,
                    target,
                    podmanConnection,
                    loadedImage.Reference,
                    loadedImage.Id,
                    secretMounts,
                    metadata,
                    podmanService,
                    caddyService,
                    reporter
                );

                if (deployed)
                {
                    reporter.Succeed(
                        "Remote deployment succeeded after independent readback",
                        new Dictionary<string, object?>
                        {
                            ["resource_key"] = resourcePrefix,
                            ["image_reference"] = loadedImage.Reference
                        }
                    );
                }

                return deployed ? 0 : 1;
            }

            var simpleDeployed = await DeploySimpleTargetAsync(
                resourcePrefix,
                targetName,
                target,
                podmanConnection,
                loadedImage.Reference,
                loadedImage.Id,
                secretMounts,
                metadata,
                podmanService,
                reporter
            );

            if (simpleDeployed)
            {
                reporter.Succeed(
                    "Remote deployment succeeded after independent readback",
                    new Dictionary<string, object?>
                    {
                        ["resource_key"] = resourcePrefix,
                        ["image_reference"] = loadedImage.Reference
                    }
                );
            }

            return simpleDeployed ? 0 : 1;
        });

        var taskTargetOption = new Option<string>("--target") { Description = "Target name" };
        var taskNameOption = new Option<string>("--task") { Description = "Flake-declared task name" };
        var taskSourceOption = new Option<string>("--source") { Description = "Immutable Nix source" };
        var taskRevisionOption = new Option<string>("--git-revision") { Description = "Full Git revision" };
        var taskRepositoryOption = new Option<string>("--repository-identity") { Description = "Repository identity" };
        var taskDigestOption = new Option<string>("--configuration-digest") { Description = "Configuration digest" };
        var taskOperationOption = new Option<string>("--operation-id") { Description = "Task operation UUID" };
        var taskResourceOption = new Option<string>("--resource-key") { Description = "Canonical resource key" };
        var taskImageOption = new Option<string>("--image-reference") { Description = "Verified deployed image reference" };
        var taskImageIdOption = new Option<string>("--image-id") { Description = "Verified immutable image ID" };
        var taskEventsOption = new Option<string>("--events") { Description = "Machine event protocol" };

        var taskCommand = new Command("task", "Run one named flake-declared operational task")
        {
            Options =
            {
                taskTargetOption,
                taskNameOption,
                taskSourceOption,
                taskRevisionOption,
                taskRepositoryOption,
                taskDigestOption,
                taskOperationOption,
                taskResourceOption,
                taskImageOption,
                taskImageIdOption,
                taskEventsOption
            }
        };

        taskCommand.SetAction(async parseResult =>
        {
            var targetName = parseResult.GetValue(taskTargetOption);
            var taskName = parseResult.GetValue(taskNameOption);
            var imageReference = parseResult.GetValue(taskImageOption);
            var imageId = parseResult.GetValue(taskImageIdOption);
            var immutable = ImmutableInvocation.Parse(
                parseResult.GetValue(taskSourceOption),
                parseResult.GetValue(taskRevisionOption),
                parseResult.GetValue(taskRepositoryOption),
                parseResult.GetValue(taskDigestOption),
                parseResult.GetValue(taskOperationOption),
                parseResult.GetValue(taskResourceOption)
            );

            if (!immutable.Success || string.IsNullOrWhiteSpace(targetName) ||
                taskName is null || !Regex.IsMatch(taskName, "^[a-z][a-z0-9_-]{0,63}$") ||
                string.IsNullOrWhiteSpace(imageReference) ||
                imageId is null || !Regex.IsMatch(imageId, "^sha256:[a-f0-9]{64}$"))
            {
                Console.Error.WriteLine(immutable.Error ?? "Task invocation identity is invalid.");
                return 1;
            }

            using var reporter = DeploymentReporter.Create(
                parseResult.GetValue(taskEventsOption),
                immutable.OperationId!
            );

            NixployConfig config;
            try
            {
                config = await configProvider.GetConfigAsync(immutable.Source!);
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return 1;
            }

            if (!config.Targets.TryGetValue(targetName, out var target) ||
                !target.Tasks.TryGetValue(taskName, out var task))
            {
                Console.Error.WriteLine("The named task is not declared by the immutable flake target.");
                return 1;
            }

            var metadata = CreateDeploymentMetadata(
                config.Project,
                targetName,
                immutable.RepositoryIdentity!,
                immutable.GitRevision!
            ) with
            {
                ConfigurationDigest = immutable.ConfigurationDigest!,
                OperationId = immutable.OperationId!,
                ResourceKey = immutable.ResourceKey!
            };

            var expectedResource = ResourcePrefix(metadata.Project, targetName);
            if (!string.Equals(expectedResource, immutable.ResourceKey, StringComparison.Ordinal))
            {
                Console.Error.WriteLine("Canonical resource key does not match the immutable task input.");
                return 1;
            }

            var connection = podmanService.GetConnectionName(expectedResource);
            if (!await podmanService.EnsureConnectionAsync(expectedResource, targetName, target))
            {
                return 1;
            }

            IReadOnlyList<Secret> secretValues;
            try
            {
                secretValues = await sopsService.LoadSecretsAsync(target);
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return 1;
            }

            var mounts = await podmanService.InstallSecretsAsync(connection, expectedResource, secretValues);
            if (mounts is null)
            {
                return 1;
            }

            reporter.Stage("starting", $"Running declared task '{taskName}' with fixed arguments");
            var result = await podmanService.RunTaskAsync(
                connection,
                expectedResource,
                imageReference,
                imageId,
                target,
                task,
                mounts,
                secretValues,
                metadata
            );

            if (!string.IsNullOrEmpty(result.Output))
            {
                Console.Error.Write(result.Output);
            }

            if (!result.Success || result.OutputTruncated)
            {
                Console.Error.WriteLine($"Task failed with exit code {result.ExitCode} or exceeded its output bound.");
                return 1;
            }

            reporter.Succeed(
                $"Declared task '{taskName}' completed",
                new Dictionary<string, object?>
                {
                    ["resource_key"] = expectedResource,
                    ["image_reference"] = imageReference,
                    ["image_id"] = imageId
                }
            );
            return 0;
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
                return 1;
            }

            NixployConfig config;

            try
            {
                config = await configProvider.GetConfigAsync(".");
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return 1;
            }

            if (!config.Targets.TryGetValue(targetName, out var target))
            {
                Console.Error.WriteLine($"Unknown target '{targetName}'.");
                return 1;
            }

            DeploymentMetadata metadata;

            try
            {
                metadata = await CreateDeploymentMetadataAsync(config.Project, targetName, commandRunner);
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return 1;
            }

            var resourcePrefix = ResourcePrefix(metadata.Project, targetName);
            var podmanConnection = podmanService.GetConnectionName(resourcePrefix);

            Console.WriteLine($"Pruning deployment identity: {resourcePrefix}");

            if (!await podmanService.EnsureConnectionAsync(resourcePrefix, targetName, target))
            {
                return 1;
            }

            if (target.Web is not null && !await caddyService.DeleteRouteAsync(resourcePrefix, target))
            {
                return 1;
            }

            if (!await podmanService.PruneTargetAsync(podmanConnection, resourcePrefix))
            {
                return 1;
            }

            Console.WriteLine("Prune completed successfully.");
            return 0;
        });

        var statusCommand = CreateStatusCommand(commandRunner, configProvider, podmanService, caddyService);

        var root = new RootCommand("Nixploy")
        {
            Subcommands =
            {
                deployCommand,
                taskCommand,
                statusCommand,
                pruneCommand
            }
        };

        return root;
    }

    private static Command CreateStatusCommand(
        ICommandRunner commandRunner,
        INixployConfigProvider configProvider,
        IPodmanService podmanService,
        ICaddyService caddyService
    )
    {
        var targetOption = new Option<string>("--target");
        var sourceOption = new Option<string>("--source");
        var revisionOption = new Option<string>("--git-revision");
        var repositoryOption = new Option<string>("--repository-identity");
        var digestOption = new Option<string>("--configuration-digest");
        var operationOption = new Option<string>("--operation-id");
        var resourceOption = new Option<string>("--resource-key");
        var containerOption = new Option<string>("--container-name");
        var imageOption = new Option<string>("--image-reference");
        var imageIdOption = new Option<string>("--image-id");
        var expectedPortOption = new Option<int?>("--expected-port");

        var command = new Command("status", "Read exact managed remote deployment status")
        {
            Options =
            {
                targetOption,
                sourceOption,
                revisionOption,
                repositoryOption,
                digestOption,
                operationOption,
                resourceOption,
                containerOption,
                imageOption,
                imageIdOption,
                expectedPortOption
            }
        };

        command.SetAction(async parseResult =>
        {
            var targetName = parseResult.GetValue(targetOption);
            var containerName = parseResult.GetValue(containerOption);
            var imageReference = parseResult.GetValue(imageOption);
            var imageId = parseResult.GetValue(imageIdOption);
            var expectedPort = parseResult.GetValue(expectedPortOption);
            var immutable = ImmutableInvocation.Parse(
                parseResult.GetValue(sourceOption),
                parseResult.GetValue(revisionOption),
                parseResult.GetValue(repositoryOption),
                parseResult.GetValue(digestOption),
                parseResult.GetValue(operationOption),
                parseResult.GetValue(resourceOption)
            );

            var protocol = Console.Out;
            Console.SetOut(Console.Error);

            try
            {
                if (!immutable.Success || string.IsNullOrWhiteSpace(targetName))
                {
                    Console.Error.WriteLine(immutable.Error ?? "Status identity is invalid.");
                    return 1;
                }

                var config = await configProvider.GetConfigAsync(immutable.Source!);
                if (!config.Targets.TryGetValue(targetName, out var target))
                {
                    return 1;
                }

                var metadata = CreateDeploymentMetadata(
                    config.Project,
                    targetName,
                    immutable.RepositoryIdentity!,
                    immutable.GitRevision!
                ) with
                {
                    ConfigurationDigest = immutable.ConfigurationDigest!,
                    OperationId = immutable.OperationId!,
                    ResourceKey = immutable.ResourceKey!
                };

                if (ResourcePrefix(metadata.Project, targetName) != immutable.ResourceKey ||
                    !await podmanService.EnsureConnectionAsync(immutable.ResourceKey!, targetName, target))
                {
                    return 1;
                }

                var connection = podmanService.GetConnectionName(immutable.ResourceKey!);
                VerifiedContainer? container = null;
                if (!string.IsNullOrWhiteSpace(containerName) &&
                    !string.IsNullOrWhiteSpace(imageReference) &&
                    !string.IsNullOrWhiteSpace(imageId))
                {
                    container = await podmanService.VerifyContainerAsync(
                        connection,
                        containerName,
                        imageReference,
                        imageId,
                        metadata
                    );
                }

                ActivePortResult ingress = target.Web is null
                    ? new ActivePortResult(true, null)
                    : await caddyService.GetActivePortAsync(immutable.ResourceKey!, target);

                var healthy = expectedPort is int port && target.Web is not null
                    ? await caddyService.CheckHealthAsync(target, port)
                    : container is not null;

                protocol.WriteLine(JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["schema"] = "nixploy.status/v1",
                    ["operation_id"] = immutable.OperationId,
                    ["resource_key"] = immutable.ResourceKey,
                    ["container_verified"] = container is not null,
                    ["container_id"] = container?.Id,
                    ["image_id"] = container?.ImageId,
                    ["ingress_available"] = ingress.Success,
                    ["active_port"] = ingress.Port,
                    ["expected_port"] = expectedPort,
                    ["healthy"] = healthy,
                    ["converged"] = container is not null && ingress.Success &&
                        (expectedPort is null || ingress.Port == expectedPort) && healthy
                }));
                protocol.Flush();
                return 0;
            }
            catch (InvalidOperationException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return 1;
            }
            finally
            {
                Console.SetOut(protocol);
            }
        });

        return command;
    }

    private static async Task<bool> DeployWebTargetAsync(
        string resourcePrefix,
        string targetName,
        NixployTarget target,
        string podmanConnection,
        string imageReference,
        string imageId,
        IReadOnlyList<SecretMount> secretMounts,
        DeploymentMetadata metadata,
        IPodmanService podmanService,
        ICaddyService caddyService,
        DeploymentReporter reporter
    )
    {
        var activePortResult = await caddyService.GetActivePortAsync(resourcePrefix, target);

        if (!activePortResult.Success)
        {
            Console.Error.WriteLine("Cannot safely select an inactive slot because Caddy state is unavailable.");
            return false;
        }

        var activePort = activePortResult.Port;
        var (slotName, slotPort) = SelectSlot(target.Web!, activePort);
        var newContainerName = $"{resourcePrefix}-{slotName}";
        var oldContainerName = activePort is null
            ? null
            : $"{resourcePrefix}-{(activePort == target.Web!.Slots.Blue ? "blue" : "green")}";

        reporter.Stage(
            "preparing_slot",
            "Preparing only the inactive managed slot",
            new Dictionary<string, object?>
            {
                ["selected_slot"] = slotName,
                ["selected_port"] = slotPort,
                ["previous_upstream"] = activePort is null ? null : $"127.0.0.1:{activePort}",
                ["container_name"] = newContainerName
            }
        );

        Console.WriteLine(activePort is null
            ? $"No active Caddy upstream found. Starting {slotName} slot on port {slotPort}."
            : $"Active port is {activePort}. Starting {slotName} slot on port {slotPort}.");

        Console.WriteLine($"Removing legacy single-container deployment '{resourcePrefix}' if it exists...");
        await podmanService.StopContainerAsync(podmanConnection, resourcePrefix);

        if (target.Run.PreStart.Count > 0)
        {
            reporter.Stage("pre_starting", "Running fixed flake-declared preparation commands");
        }

        if (!await podmanService.RunPreStartCommandsAsync(
                podmanConnection,
                imageReference,
                target.Run.PreStart,
                target.Run.Network,
                target.Run.Environment,
                slotPort,
                secretMounts
            ))
        {
            return false;
        }

        Console.WriteLine($"Starting {slotName} container '{newContainerName}' from image '{imageReference}'...");
        reporter.Stage(
            "starting",
            "Starting the verified image in the inactive slot",
            new Dictionary<string, object?> { ["container_name"] = newContainerName }
        );

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
            await podmanService.StopContainerAsync(podmanConnection, newContainerName);
            return false;
        }

        reporter.Stage("health_checking", "Checking target-local candidate health");

        if (!await caddyService.CheckHealthAsync(target, slotPort))
        {
            Console.Error.WriteLine("New slot failed health check. Leaving existing Caddy route unchanged.");
            await podmanService.StopContainerAsync(podmanConnection, newContainerName);
            return false;
        }

        reporter.Stage("switching", "Switching only the identified Caddy upstream");

        if (!await caddyService.SwitchAsync(resourcePrefix, target, slotPort))
        {
            Console.Error.WriteLine("New slot is healthy, but the Caddy switch did not complete.");
            if (activePort is not null)
            {
                await RestoreRouteAsync(resourcePrefix, target, activePort, caddyService);
            }
            await podmanService.StopContainerAsync(podmanConnection, newContainerName);
            return false;
        }

        var switchedPort = await caddyService.GetActivePortAsync(resourcePrefix, target);
        if (!switchedPort.Success || switchedPort.Port != slotPort)
        {
            Console.Error.WriteLine("Independent Caddy readback did not match the selected slot; restoring the prior route.");
            await RestoreRouteAsync(resourcePrefix, target, activePort, caddyService);
            await podmanService.StopContainerAsync(podmanConnection, newContainerName);
            return false;
        }

        var verifiedContainer = await podmanService.VerifyContainerAsync(
            podmanConnection,
            newContainerName,
            imageReference,
            imageId,
            metadata
        );
        if (verifiedContainer is null)
        {
            Console.Error.WriteLine("Independent container readback did not match the expected managed identity.");
            await RestoreRouteAsync(resourcePrefix, target, activePort, caddyService);
            await podmanService.StopContainerAsync(podmanConnection, newContainerName);
            return false;
        }

        reporter.Stage(
            "verifying",
            "Independent ingress and container readback matched the selected slot",
            new Dictionary<string, object?>
            {
                ["selected_slot"] = slotName,
                ["selected_port"] = slotPort,
                ["verified_upstream"] = $"127.0.0.1:{slotPort}",
                ["container_name"] = verifiedContainer.Name,
                ["container_id"] = verifiedContainer.Id,
                ["image_reference"] = verifiedContainer.ImageReference,
                ["image_id"] = verifiedContainer.ImageId
            }
        );

        if (!string.IsNullOrWhiteSpace(oldContainerName) && oldContainerName != newContainerName)
        {
            Console.WriteLine($"Stopping old container '{oldContainerName}'...");
            await podmanService.StopContainerAsync(podmanConnection, oldContainerName);
        }

        Console.WriteLine($"Deployment completed successfully. {target.Web!.Domain} now routes to {slotName} ({slotPort}).");
        return true;
    }

    private static async Task RestoreRouteAsync(
        string resourcePrefix,
        NixployTarget target,
        int? priorPort,
        ICaddyService caddyService
    )
    {
        var restored = priorPort is int port
            ? await caddyService.SwitchAsync(resourcePrefix, target, port)
            : await caddyService.DeleteRouteAsync(resourcePrefix, target);

        if (!restored)
        {
            Console.Error.WriteLine("Caddy compensation failed; the prior route could not be proven restored.");
            return;
        }

        var readback = await caddyService.GetActivePortAsync(resourcePrefix, target);
        if (!readback.Success || readback.Port != priorPort)
        {
            Console.Error.WriteLine("Caddy compensation completed but independent readback did not match prior state.");
        }
    }

    private static async Task<bool> DeploySimpleTargetAsync(
        string resourcePrefix,
        string targetName,
        NixployTarget target,
        string podmanConnection,
        string imageReference,
        string imageId,
        IReadOnlyList<SecretMount> secretMounts,
        DeploymentMetadata metadata,
        IPodmanService podmanService,
        DeploymentReporter reporter
    )
    {
        var containerName = resourcePrefix;

        if (target.Run.PreStart.Count > 0)
        {
            reporter.Stage("pre_starting", "Running fixed flake-declared preparation commands");
        }

        if (!await podmanService.RunPreStartCommandsAsync(
                podmanConnection,
                imageReference,
                target.Run.PreStart,
                target.Run.Network,
                target.Run.Environment,
                null,
                secretMounts
            ))
        {
            return false;
        }

        Console.WriteLine($"Starting container '{containerName}' from image '{imageReference}'...");
        reporter.Stage(
            "starting",
            "Starting the verified image",
            new Dictionary<string, object?> { ["container_name"] = containerName }
        );

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
            return false;
        }

        var verifiedContainer = await podmanService.VerifyContainerAsync(
            podmanConnection,
            containerName,
            imageReference,
            imageId,
            metadata
        );
        if (verifiedContainer is null)
        {
            await podmanService.StopContainerAsync(podmanConnection, containerName);
            return false;
        }

        reporter.Stage(
            "verifying",
            "Independent container readback matched the managed identity",
            new Dictionary<string, object?>
            {
                ["container_name"] = verifiedContainer.Name,
                ["container_id"] = verifiedContainer.Id,
                ["image_reference"] = verifiedContainer.ImageReference,
                ["image_id"] = verifiedContainer.ImageId
            }
        );
        Console.WriteLine("Deployment completed successfully.");
        return true;
    }

    private static DeploymentMetadata CreateDeploymentMetadata(
        string project,
        string targetName,
        string repositoryIdentity,
        string gitRevision
    )
    {
        if (string.IsNullOrWhiteSpace(project))
        {
            throw new InvalidOperationException("nixploy project is required. Set `project = \"your-app\";` in nixploy.lib.makeConfig.");
        }

        return new DeploymentMetadata(
            project,
            ShortHash(repositoryIdentity),
            targetName,
            repositoryIdentity,
            gitRevision,
            DateTimeOffset.UtcNow.ToString("O")
        );
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

        return new DeploymentMetadata(project, projectId, targetName, origin, commit, deployedAt);
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

    private static string ResourcePrefix(string project, string targetName)
    {
        return ManagedResourceIdentity.Derive(project, targetName);
    }

    private static string ShortHash(string value)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes)[..10].ToLowerInvariant();
    }

    private sealed record ImmutableInvocation(
        bool Success,
        string? Error,
        string? Source,
        string? GitRevision,
        string? RepositoryIdentity,
        string? ConfigurationDigest,
        string? OperationId,
        string? ResourceKey
    )
    {
        private static readonly Regex GitOid = new("^[0-9a-f]{40}$", RegexOptions.CultureInvariant);
        private static readonly Regex Digest = new("^[0-9a-f]{64}$", RegexOptions.CultureInvariant);
        private static readonly Regex Resource = new("^nixploy-[a-z0-9][a-z0-9_-]{0,126}$", RegexOptions.CultureInvariant);
        private static readonly Regex Repository = new("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", RegexOptions.CultureInvariant);

        public static ImmutableInvocation Parse(
            string? source,
            string? gitRevision,
            string? repositoryIdentity,
            string? configurationDigest,
            string? operationId,
            string? resourceKey
        )
        {
            string? error = null;

            if (string.IsNullOrWhiteSpace(source) ||
                !source.StartsWith("/nix/store/", StringComparison.Ordinal) ||
                source.Contains('\n') || source.Contains('\0'))
            {
                error = "--source must be one absolute /nix/store path.";
            }
            else if (gitRevision is null || !GitOid.IsMatch(gitRevision))
            {
                error = "--git-revision must be one full lowercase Git commit.";
            }
            else if (repositoryIdentity is null || !Repository.IsMatch(repositoryIdentity))
            {
                error = "--repository-identity must be owner/repository.";
            }
            else if (configurationDigest is null || !Digest.IsMatch(configurationDigest))
            {
                error = "--configuration-digest must be a lowercase SHA-256 digest.";
            }
            else if (!Guid.TryParse(operationId, out _))
            {
                error = "--operation-id must be a UUID.";
            }
            else if (resourceKey is null || !Resource.IsMatch(resourceKey))
            {
                error = "--resource-key is invalid.";
            }

            return new ImmutableInvocation(
                error is null,
                error,
                source,
                gitRevision,
                repositoryIdentity,
                configurationDigest,
                operationId,
                resourceKey
            );
        }
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
