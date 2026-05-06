using System.Text.Json;

namespace Nixploy.Cli;

public sealed class NixployConfigProvider(ICommandRunner commandRunner) : INixployConfigProvider
{
    private const string SupportedSchema = "v0.2";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private Task<NixployConfig>? configTask;

    public Task<NixployConfig> GetConfigAsync()
    {
        configTask ??= LoadConfigAsync();
        return configTask;
    }

    private async Task<NixployConfig> LoadConfigAsync()
    {
        CommandRunResult result = await commandRunner.RunAsync(
            "nix",
            ["eval", ".#nixploy", "--json"],
            new CommandRunOptions { StreamOutput = false }
        );

        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"Failed to evaluate .#nixploy.\n{result.StdError}"
            );
        }

        try
        {
            var config = JsonSerializer.Deserialize<NixployConfig>(result.StdOutput, JsonOptions)
                ?? throw new InvalidOperationException(".#nixploy evaluated to empty JSON.");

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
                "Failed to parse .#nixploy JSON.",
                exception
            );
        }
    }
}
