using System.Text.Json;

namespace Nixploy.Cli;

public sealed class NixployConfigProvider(ICommandRunner commandRunner) : INixployConfigProvider
{
    private const string SupportedSchema = "v0.2";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly Dictionary<string, Task<NixployConfig>> configTasks = new(StringComparer.Ordinal);

    public Task<NixployConfig> GetConfigAsync(string source)
    {
        if (string.IsNullOrWhiteSpace(source))
        {
            throw new InvalidOperationException("An immutable source path is required.");
        }

        if (!configTasks.TryGetValue(source, out var task))
        {
            task = LoadConfigAsync(source);
            configTasks[source] = task;
        }

        return task;
    }

    private async Task<NixployConfig> LoadConfigAsync(string source)
    {
        CommandRunResult result = await commandRunner.RunAsync(
            "nix",
            ["eval", "--json", "--no-write-lock-file", $"{source}#nixploy"],
            new CommandRunOptions { StreamOutput = false }
        );

        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"Failed to evaluate immutable source '{source}#nixploy'.\n{result.StdError}"
            );
        }

        try
        {
            var config = JsonSerializer.Deserialize<NixployConfig>(result.StdOutput, JsonOptions)
                ?? throw new InvalidOperationException("The immutable nixploy source evaluated to empty JSON.");

            if (config.Schema != SupportedSchema)
            {
                throw new InvalidOperationException(
                    $"Unsupported nixploy schema '{config.Schema}'. Expected '{SupportedSchema}'. " +
                    "Make sure your flake uses nixploy.lib.makeConfig from a compatible nixploy input."
                );
            }

            return config;
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException(
                "Failed to parse immutable nixploy source JSON.",
                exception
            );
        }
    }
}
