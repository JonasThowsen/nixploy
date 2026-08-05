using System.Text;

namespace Nixploy.Cli;

public sealed class SopsService(
    ICommandRunner commandRunner,
    Func<string?>? ageKeyFile = null
) : ISopsService
{
    public async Task<IReadOnlyList<Secret>> LoadSecretsAsync(NixployTarget target)
    {
        if (target.Secrets.Count == 0)
        {
            return [];
        }

        var ageIdentityPath = RequirePrivateAgeKeyFile(
            ageKeyFile?.Invoke() ??
            Environment.GetEnvironmentVariable("SOPS_AGE_KEY_FILE") ??
            Environment.GetEnvironmentVariable("SOPS_AGE_SSH_PRIVATE_KEY_FILE")
        );
        var secrets = new Dictionary<string, SecretSource>(StringComparer.Ordinal);

        foreach (var (label, path) in target.Secrets.OrderBy(secret => secret.Key))
        {
            Console.WriteLine($"Decrypting secrets '{label}'...");

            Console.WriteLine($"Using worker-owned age identity from {ageIdentityPath}.");

            CommandRunResult result = await commandRunner.RunAsync(
                "sops",
                ["--decrypt", "--input-type", "dotenv", "--output-type", "dotenv", path],
                new CommandRunOptions { StreamOutput = false }
            );

            if (result.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    $"Failed to decrypt secrets '{label}' from {path}.\n{result.StdError}"
                );
            }

            foreach (var secret in ParseDotEnv(result.StdOutput))
            {
                if (secrets.TryGetValue(secret.Name, out var existing))
                {
                    throw new InvalidOperationException(
                        $"Duplicate secret '{secret.Name}' found in '{existing.Label}' and '{label}'. " +
                        "Secret names must be unique across all configured SOPS files."
                    );
                }

                secrets.Add(secret.Name, new SecretSource(label, secret));
            }
        }

        return [.. secrets.Values.Select(source => source.Secret)];
    }

    private static string RequirePrivateAgeKeyFile(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw new InvalidOperationException(
                "A SOPS age or age-compatible SSH identity must name an absolute worker-owned file."
            );
        }

        var info = new FileInfo(path);
        if (!info.Exists)
        {
            throw new InvalidOperationException("The configured worker age identity file does not exist.");
        }

        if (!OperatingSystem.IsWindows())
        {
            var exposed = info.UnixFileMode &
                (UnixFileMode.GroupRead |
                 UnixFileMode.GroupWrite |
                 UnixFileMode.GroupExecute |
                 UnixFileMode.OtherRead |
                 UnixFileMode.OtherWrite |
                 UnixFileMode.OtherExecute);

            if (exposed != 0)
            {
                throw new InvalidOperationException(
                    "The configured worker age identity file must not be accessible by group or other users."
                );
            }
        }

        return info.FullName;
    }

    private static List<Secret> ParseDotEnv(string content)
    {
        var secrets = new List<Secret>();

        foreach (var rawLine in content.Split('\n'))
        {
            var line = rawLine.Trim();

            if (line.Length == 0 || line.StartsWith('#'))
            {
                continue;
            }

            if (line.StartsWith("export ", StringComparison.Ordinal))
            {
                line = line[7..].TrimStart();
            }

            var equalsIndex = line.IndexOf('=');

            if (equalsIndex <= 0)
            {
                continue;
            }

            var name = line[..equalsIndex].Trim();
            var value = line[(equalsIndex + 1)..].Trim();

            if (string.IsNullOrWhiteSpace(name))
            {
                continue;
            }

            secrets.Add(new Secret(name, Unquote(value)));
        }

        return secrets;
    }

    private static string Unquote(string value)
    {
        if (value.Length >= 2 && value[0] == '"' && value[^1] == '"')
        {
            return UnescapeDoubleQuoted(value[1..^1]);
        }

        if (value.Length >= 2 && value[0] == '\'' && value[^1] == '\'')
        {
            return value[1..^1];
        }

        var commentIndex = value.IndexOf(" #", StringComparison.Ordinal);

        if (commentIndex >= 0)
        {
            value = value[..commentIndex].TrimEnd();
        }

        return value;
    }

    private static string UnescapeDoubleQuoted(string value)
    {
        var builder = new StringBuilder(value.Length);

        for (var i = 0; i < value.Length; i++)
        {
            if (value[i] != '\\' || i == value.Length - 1)
            {
                builder.Append(value[i]);
                continue;
            }

            i++;

            builder.Append(value[i] switch
            {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                _ => value[i]
            });
        }

        return builder.ToString();
    }

    private sealed record SecretSource(string Label, Secret Secret);
}
