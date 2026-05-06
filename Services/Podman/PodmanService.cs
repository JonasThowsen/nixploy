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

        Console.WriteLine($"Checking Podman connection '{connectionName}'...");

        var storedIdentity = await GetStoredConnectionIdentityAsync(connectionName);

        if (!string.IsNullOrWhiteSpace(storedIdentity))
        {
            Console.WriteLine(
                $"Existing Podman connection '{connectionName}' stores identity '{storedIdentity}'. " +
                "Recreating it without a stored identity so SSH/ssh-agent can handle authentication."
            );

            await commandRunner.RunAsync(
                "podman",
                ["system", "connection", "rm", connectionName],
                new CommandRunOptions { StreamOutput = false }
            );
        }

        CommandRunResult infoResult = await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "info"],
            new CommandRunOptions { Interactive = true }
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
            new CommandRunOptions { Interactive = true }
        );

        if (addResult.ExitCode != 0)
        {
            Console.Error.WriteLine($"Failed to create Podman connection '{connectionName}'.");
            return false;
        }

        CommandRunResult verifyResult = await commandRunner.RunAsync(
            "podman",
            ["--connection", connectionName, "info"],
            new CommandRunOptions { Interactive = true }
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

        return new LoadedImage(imageReference);
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

    private async Task<string?> GetStoredConnectionIdentityAsync(string connectionName)
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

                return connection.TryGetProperty("Identity", out var identity)
                    ? identity.GetString()
                    : null;
            }
        }
        catch (JsonException)
        {
            return null;
        }

        return null;
    }

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

    private static void AddLabels(List<string> arguments, DeploymentMetadata metadata)
    {
        var labels = new Dictionary<string, string>
        {
            ["nixploy.project"] = metadata.Project,
            ["nixploy.project_id"] = metadata.ProjectId,
            ["nixploy.target"] = metadata.Target,
            ["nixploy.git_commit"] = metadata.GitCommit,
            ["nixploy.deployed_at"] = metadata.DeployedAt
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
