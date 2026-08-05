using System.Text.Json;

namespace Nixploy.Cli;

public sealed class PodmanService(ICommandRunner commandRunner) : IPodmanService
{

    public string GetConnectionName(string resourcePrefix)
    {
        return resourcePrefix;
    }

    public async Task<bool> EnsureConnectionAsync(string resourcePrefix, string targetName, NixployTarget target)
    {
        var connectionName = GetConnectionName(resourcePrefix);

        if (!await VerifySshTargetAsync(target))
        {
            return false;
        }

        Console.WriteLine($"Checking Podman connection '{connectionName}'...");

        var storedConnection = await GetStoredConnectionAsync(connectionName);

        if (storedConnection is not null)
        {
            string? recreationReason = null;

            if (!string.IsNullOrWhiteSpace(storedConnection.Identity))
            {
                recreationReason =
                    $"it stores identity '{storedConnection.Identity}', but SSH/ssh-agent should handle authentication.";
            }
            else if (!ConnectionMatchesTarget(storedConnection.Uri, target))
            {
                recreationReason =
                    $"it points to '{storedConnection.Uri ?? "an unknown endpoint"}' instead of " +
                    $"'{target.User}@{target.Ip}:{target.Port}'.";
            }

            if (recreationReason is not null)
            {
                Console.WriteLine(
                    $"Existing Podman connection '{connectionName}' is stale because {recreationReason} Recreating it."
                );

                await commandRunner.RunAsync(
                    "podman",
                    ["system", "connection", "rm", connectionName],
                    new CommandRunOptions { StreamOutput = false }
                );
            }
        }

        CommandRunResult infoResult = await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "info"],
            new CommandRunOptions { StreamOutput = false }
        );

        if (infoResult.ExitCode == 0)
        {
            Console.WriteLine($"Using existing Podman connection '{connectionName}'.");
            return true;
        }

        Console.WriteLine($"Creating Podman connection '{connectionName}' for {target.User}@{target.Ip}:{target.Port}...");

        var arguments = new List<string>
        {
            "system",
            "connection",
            "add",
            connectionName,
            "--port",
            target.Port.ToString()
        };

        if (!string.IsNullOrWhiteSpace(target.IdentityFile))
        {
            Console.WriteLine(
                "Target has identityFile configured. Podman connections will use SSH/ssh-agent instead of storing " +
                "the identity file, so passphrase-protected keys keep working for commands that use stdin."
            );
            Console.WriteLine($"Make sure the key is available to ssh-agent: ssh-add {ExpandHome(target.IdentityFile)}");
        }

        arguments.Add($"{target.User}@{target.Ip}");

        CommandRunResult addResult = await commandRunner.RunAsync(
            "podman",
            arguments,
            new CommandRunOptions { StreamOutput = false }
        );

        if (addResult.ExitCode != 0)
        {
            Console.Error.WriteLine($"Failed to create Podman connection '{connectionName}'.");
            Console.Error.WriteLine(addResult.StdError);
            return false;
        }

        CommandRunResult verifyResult = await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "info"],
            new CommandRunOptions { StreamOutput = false }
        );

        if (verifyResult.ExitCode == 0)
        {
            Console.WriteLine($"Podman connection '{connectionName}' is ready.");
            return true;
        }

        Console.Error.WriteLine($"Podman connection '{connectionName}' was created, but could not be used.");
        Console.Error.WriteLine(verifyResult.StdError);
        return false;
    }

    private async Task<bool> VerifySshTargetAsync(NixployTarget target)
    {
        var arguments = new List<string>
        {
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
            "-p", target.Port.ToString()
        };

        if (!string.IsNullOrWhiteSpace(target.IdentityFile))
        {
            arguments.Add("-i");
            arguments.Add(ExpandHome(target.IdentityFile));
        }

        arguments.Add("--");
        arguments.Add($"{target.User}@{target.Ip}");
        arguments.Add("true");

        var result = await commandRunner.RunAsync(
            "ssh",
            arguments,
            new CommandRunOptions { StreamOutput = false }
        );

        if (result.ExitCode == 0)
        {
            return true;
        }

        Console.Error.WriteLine("Strict SSH host-key and authentication preflight failed.");
        Console.Error.WriteLine(result.StdError);
        return false;
    }

    public async Task<LoadedImage?> LoadImageAsync(string connectionName, string imagePath)
    {
        CommandRunResult result = await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "load", "-i", imagePath]
        );

        if (result.ExitCode != 0)
        {
            Console.Error.WriteLine($"Image load failed with exit code {result.ExitCode}.");
            return null;
        }

        var imageReference = ParseLoadedImageReference(result.StdOutput);

        if (string.IsNullOrWhiteSpace(imageReference))
        {
            Console.Error.WriteLine("Image loaded, but Podman did not report the loaded image name.");
            return null;
        }

        var inspect = await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "inspect", "--type", "image", imageReference],
            new CommandRunOptions { StreamOutput = false }
        );

        if (inspect.ExitCode != 0)
        {
            Console.Error.WriteLine("Image loaded, but its immutable image ID could not be read back.");
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(inspect.StdOutput);
            if (document.RootElement.ValueKind != JsonValueKind.Array ||
                document.RootElement.GetArrayLength() != 1)
            {
                return null;
            }

            var imageId = document.RootElement[0].GetProperty("Id").GetString();
            if (string.IsNullOrWhiteSpace(imageId))
            {
                return null;
            }

            return new LoadedImage(imageReference, imageId);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            Console.Error.WriteLine("Loaded image identity response was malformed.");
            Console.Error.WriteLine(exception.Message);
            return null;
        }
    }

    public async Task<IReadOnlyList<SecretMount>?> InstallSecretsAsync(
        string connectionName,
        string resourcePrefix,
        IReadOnlyList<Secret> secrets
    )
    {
        if (secrets.Count == 0)
        {
            return [];
        }

        Console.WriteLine($"Installing {secrets.Count} secret(s) into remote Podman...");

        var mounts = new List<SecretMount>();

        foreach (var secret in secrets)
        {
            var remoteName = $"{resourcePrefix}-{secret.Name}";

            await commandRunner.RunAsync(
                "podman",
                ["--connection", connectionName, "secret", "rm", remoteName],
                new CommandRunOptions { StreamOutput = false }
            );

            CommandRunResult createResult = await commandRunner.RunAsync(
                "podman",
                ["--connection", connectionName, "secret", "create", remoteName, "-"],
                new CommandRunOptions
                {
                    StreamOutput = false,
                    StandardInput = secret.Value
                }
            );

            if (createResult.ExitCode != 0)
            {
                Console.Error.WriteLine($"Failed to create Podman secret for '{secret.Name}'.");
                Console.Error.WriteLine(createResult.StdError);
                return null;
            }

            mounts.Add(new SecretMount(remoteName, secret.Name));
        }

        Console.WriteLine("Secrets installed successfully.");
        return mounts;
    }

    public async Task<bool> RunPreStartCommandsAsync(
        string connectionName,
        string imageReference,
        IReadOnlyList<IReadOnlyList<string>> commands,
        string? network,
        IReadOnlyDictionary<string, string> environment,
        int? port,
        IReadOnlyList<SecretMount> secrets
    )
    {
        for (var index = 0; index < commands.Count; index++)
        {
            var command = commands[index];

            if (command.Count == 0)
            {
                continue;
            }

            Console.WriteLine($"Running pre-start command {index + 1}/{commands.Count}: {string.Join(" ", command)}");

            var arguments = BuildRunArguments(connectionName, secrets);
            arguments.Add("--rm");
            AddNetwork(arguments, network);
            AddEnvironment(arguments, environment, port);
            arguments.Add(imageReference);
            arguments.AddRange(command);

            CommandRunResult result = await commandRunner.RunAsync("podman", arguments);

            if (result.ExitCode != 0)
            {
                Console.Error.WriteLine($"Pre-start command failed with exit code {result.ExitCode}.");
                return false;
            }
        }

        return true;
    }

    public async Task<bool> RunImageAsync(
        string connectionName,
        string containerName,
        string imageReference,
        NixployRunConfig runConfig,
        int? port,
        IReadOnlyList<SecretMount> secrets,
        DeploymentMetadata metadata
    )
    {
        await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "rm", "-f", containerName],
            new CommandRunOptions { StreamOutput = false }
        );

        var arguments = BuildRunArguments(connectionName, secrets);
        arguments.Add("-d");
        arguments.Add("--name");
        arguments.Add(containerName);

        AddNetwork(arguments, runConfig.Network);
        AddEnvironment(arguments, runConfig.Environment, port);
        AddLabels(arguments, metadata);

        foreach (var portMapping in runConfig.Ports)
        {
            arguments.Add("-p");
            arguments.Add(portMapping);
        }

        arguments.Add(imageReference);

        if (runConfig.Command is { Count: > 0 })
        {
            arguments.AddRange(runConfig.Command);
        }

        CommandRunResult result = await commandRunner.RunAsync("podman", arguments);

        if (result.ExitCode == 0)
        {
            return true;
        }

        Console.Error.WriteLine($"Container start failed with exit code {result.ExitCode}.");
        return false;
    }

    public async Task<VerifiedContainer?> VerifyContainerAsync(
        string connectionName,
        string containerName,
        string imageReference,
        string imageId,
        DeploymentMetadata metadata
    )
    {
        var result = await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "inspect", "--type", "container", containerName],
            new CommandRunOptions { StreamOutput = false }
        );

        if (result.ExitCode != 0)
        {
            Console.Error.WriteLine($"Could not read back candidate container '{containerName}'.");
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(result.StdOutput);
            if (document.RootElement.ValueKind != JsonValueKind.Array ||
                document.RootElement.GetArrayLength() != 1)
            {
                return null;
            }

            var container = document.RootElement[0];
            var id = container.GetProperty("Id").GetString();
            var name = container.GetProperty("Name").GetString()?.TrimStart('/');
            var observedImageId = container.GetProperty("Image").GetString();
            var state = container.GetProperty("State");
            var config = container.GetProperty("Config");
            var configuredImage = config.GetProperty("Image").GetString();
            var labels = config.GetProperty("Labels");

            var valid = !string.IsNullOrWhiteSpace(id) &&
                string.Equals(name, containerName, StringComparison.Ordinal) &&
                state.GetProperty("Running").GetBoolean() &&
                string.Equals(configuredImage, imageReference, StringComparison.Ordinal) &&
                string.Equals(observedImageId, imageId, StringComparison.Ordinal) &&
                LabelEquals(labels, "io.nixploy.managed", "true") &&
                LabelEquals(labels, "io.nixploy.project", metadata.Project) &&
                LabelEquals(labels, "io.nixploy.target", metadata.Target) &&
                LabelEquals(labels, "io.nixploy.repository", metadata.Repository) &&
                LabelEquals(labels, "io.nixploy.revision", metadata.GitCommit) &&
                LabelEquals(labels, "io.nixploy.configuration_digest", metadata.ConfigurationDigest) &&
                LabelEquals(labels, "io.nixploy.operation_id", metadata.OperationId) &&
                LabelEquals(labels, "io.nixploy.resource_key", metadata.ResourceKey);

            if (!valid)
            {
                Console.Error.WriteLine("Candidate container readback did not match the expected managed identity.");
                return null;
            }

            return new VerifiedContainer(id!, name!, configuredImage!, observedImageId!);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            Console.Error.WriteLine("Candidate container readback was malformed.");
            Console.Error.WriteLine(exception.Message);
            return null;
        }
    }

    public async Task StopContainerAsync(string connectionName, string containerName)
    {
        await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "rm", "-f", containerName],
            new CommandRunOptions { StreamOutput = false }
        );
    }

    public async Task<bool> PruneTargetAsync(string connectionName, string resourcePrefix)
    {
        Console.WriteLine($"Removing containers for '{resourcePrefix}'...");

        foreach (var containerName in new[] { resourcePrefix, $"{resourcePrefix}-blue", $"{resourcePrefix}-green" })
        {
            await StopContainerAsync(connectionName, containerName);
        }

        Console.WriteLine($"Removing secrets with prefix '{resourcePrefix}-'...");

        var listResult = await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "secret", "ls", "--format", "{{.Name}}"],
            new CommandRunOptions { StreamOutput = false }
        );

        if (listResult.ExitCode != 0)
        {
            Console.Error.WriteLine("Failed to list Podman secrets.");
            Console.Error.WriteLine(listResult.StdError);
            return false;
        }

        foreach (var secretName in listResult.StdOutput.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (!secretName.StartsWith($"{resourcePrefix}-", StringComparison.Ordinal))
            {
                continue;
            }

            await commandRunner.RunAsync(
                "podman",
                ["--connection", connectionName, "secret", "rm", secretName],
                new CommandRunOptions { StreamOutput = false }
            );
        }

        return true;
    }

    private async Task<StoredPodmanConnection?> GetStoredConnectionAsync(string connectionName)
    {
        var result = await commandRunner.RunAsync(
            "podman",
            ["system", "connection", "list", "--format", "json"],
            new CommandRunOptions { StreamOutput = false }
        );

        if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.StdOutput))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(result.StdOutput);

            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            foreach (var connection in document.RootElement.EnumerateArray())
            {
                if (!connection.TryGetProperty("Name", out var name) || name.GetString() != connectionName)
                {
                    continue;
                }

                var uri = connection.TryGetProperty("URI", out var uriElement)
                    ? uriElement.GetString()
                    : null;
                var identity = connection.TryGetProperty("Identity", out var identityElement)
                    ? identityElement.GetString()
                    : null;

                return new StoredPodmanConnection(uri, identity);
            }
        }
        catch (JsonException)
        {
            return null;
        }

        return null;
    }

    private static bool ConnectionMatchesTarget(string? connectionUri, NixployTarget target)
    {
        if (!Uri.TryCreate(connectionUri, UriKind.Absolute, out var uri) ||
            !string.Equals(uri.Scheme, "ssh", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var user = Uri.UnescapeDataString(uri.UserInfo.Split(':', 2)[0]);
        var targetHost = target.Ip.Trim('[', ']');

        return string.Equals(user, target.User, StringComparison.Ordinal) &&
            string.Equals(uri.Host, targetHost, StringComparison.OrdinalIgnoreCase) &&
            uri.Port == target.Port;
    }

    private sealed record StoredPodmanConnection(string? Uri, string? Identity);

    private static List<string> BuildRunArguments(
        string connectionName,
        IReadOnlyList<SecretMount> secrets
    )
    {
        var arguments = new List<string>
        {
            "--connection",
            connectionName,
            "run"
        };

        foreach (var secret in secrets)
        {
            arguments.Add("--secret");
            arguments.Add($"source={secret.Source},type=env,target={secret.Target}");
        }

        return arguments;
    }

    private static bool LabelEquals(JsonElement labels, string name, string expected)
    {
        return labels.ValueKind == JsonValueKind.Object &&
            labels.TryGetProperty(name, out var value) &&
            value.ValueKind == JsonValueKind.String &&
            string.Equals(value.GetString(), expected, StringComparison.Ordinal);
    }

    private static void AddLabels(List<string> arguments, DeploymentMetadata metadata)
    {
        var labels = new Dictionary<string, string>
        {
            ["nixploy.project"] = metadata.Project,
            ["nixploy.project_id"] = metadata.ProjectId,
            ["nixploy.target"] = metadata.Target,
            ["nixploy.repository"] = metadata.Repository,
            ["nixploy.git_commit"] = metadata.GitCommit,
            ["nixploy.deployed_at"] = metadata.DeployedAt,
            ["io.nixploy.managed"] = "true",
            ["io.nixploy.project"] = metadata.Project,
            ["io.nixploy.target"] = metadata.Target,
            ["io.nixploy.repository"] = metadata.Repository,
            ["io.nixploy.revision"] = metadata.GitCommit,
            ["io.nixploy.deployed_at"] = metadata.DeployedAt,
            ["io.nixploy.configuration_digest"] = metadata.ConfigurationDigest,
            ["io.nixploy.operation_id"] = metadata.OperationId,
            ["io.nixploy.resource_key"] = metadata.ResourceKey,
            ["org.opencontainers.image.source"] = metadata.Repository,
            ["org.opencontainers.image.revision"] = metadata.GitCommit
        };

        foreach (var (name, value) in labels)
        {
            arguments.Add("--label");
            arguments.Add($"{name}={value}");
        }
    }

    private static void AddEnvironment(
        List<string> arguments,
        IReadOnlyDictionary<string, string> environment,
        int? port
    )
    {
        foreach (var (name, value) in environment)
        {
            arguments.Add("-e");
            arguments.Add($"{name}={RenderTemplate(value, port)}");
        }
    }

    private static string RenderTemplate(string value, int? port)
    {
        return port is null ? value : value.Replace("{port}", port.Value.ToString());
    }

    private static void AddNetwork(List<string> arguments, string? network)
    {
        if (string.IsNullOrWhiteSpace(network))
        {
            return;
        }

        arguments.Add("--network");
        arguments.Add(network);
    }

    private static string ExpandHome(string path)
    {
        if (path == "~")
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        if (path.StartsWith("~/", StringComparison.Ordinal))
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                path[2..]
            );
        }

        return path;
    }

    private static string? ParseLoadedImageReference(string output)
    {
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            const string prefix = "Loaded image: ";

            if (line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return line[prefix.Length..].Trim();
            }
        }

        return null;
    }
}
