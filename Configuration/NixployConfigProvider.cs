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

            ValidateReadOnlyBinds(config);
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

    private static void ValidateReadOnlyBinds(NixployConfig config)
    {
        foreach (var (targetName, target) in config.Targets)
        {
            if (target.Run is null || target.Run.ReadOnlyBinds is null)
            {
                throw new InvalidOperationException(
                    $"Target '{targetName}' run.readOnlyBinds must be a list."
                );
            }

            var destinations = new HashSet<string>(StringComparer.Ordinal);

            for (var index = 0; index < target.Run.ReadOnlyBinds.Count; index++)
            {
                var bind = target.Run.ReadOnlyBinds[index]
                    ?? throw new InvalidOperationException(
                        $"Target '{targetName}' run.readOnlyBinds[{index}] must be an object."
                    );
                var optionName = $"targets.{targetName}.run.readOnlyBinds[{index}]";

                if (bind.Extra.Count > 0)
                {
                    throw new InvalidOperationException(
                        $"{optionName} contains unsupported field(s): {string.Join(", ", bind.Extra.Keys.Order())}. " +
                        "Read-only bind mounts accept only source and destination."
                    );
                }

                ValidateUnixPath(bind.Source, $"{optionName}.source");
                ValidateUnixPath(bind.Destination, $"{optionName}.destination");

                if (string.Equals(bind.Source, bind.Destination, StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        $"{optionName} source and destination must differ."
                    );
                }

                if (!destinations.Add(bind.Destination))
                {
                    throw new InvalidOperationException(
                        $"Target '{targetName}' has duplicate read-only bind destination '{bind.Destination}'."
                    );
                }
            }
        }
    }

    private static void ValidateUnixPath(string? path, string optionName)
    {
        if (string.IsNullOrEmpty(path))
        {
            throw new InvalidOperationException($"{optionName} must be nonempty.");
        }

        if (path[0] != '/')
        {
            throw new InvalidOperationException($"{optionName} must be an absolute Unix path.");
        }

        if (path == "/")
        {
            throw new InvalidOperationException($"{optionName} must not be the filesystem root.");
        }

        if (path.Contains(',') || path.Any(char.IsControl))
        {
            throw new InvalidOperationException(
                $"{optionName} must not contain commas, NUL, or control characters."
            );
        }

        var segments = path.Split('/');

        if (segments.Skip(1).Any(segment => segment.Length == 0 || segment is "." or ".."))
        {
            throw new InvalidOperationException(
                $"{optionName} must be normalized without empty, dot, or dot-dot path segments."
            );
        }
    }
}
