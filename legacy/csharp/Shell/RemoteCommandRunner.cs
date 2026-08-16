namespace Nixploy.Cli;

public sealed class RemoteCommandRunner(ICommandRunner commandRunner) : IRemoteCommandRunner
{
    public Task<CommandRunResult> RunAsync(
        NixployTarget target,
        string command,
        CommandRunOptions? options = null
    )
    {
        var arguments = new List<string>
        {
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ConnectTimeout=10",
            "-p",
            target.Port.ToString()
        };

        var identityFile = System.Environment.GetEnvironmentVariable("NIXPLOY_SSH_IDENTITY_FILE") ??
            target.IdentityFile;
        var knownHostsFile = System.Environment.GetEnvironmentVariable("NIXPLOY_SSH_KNOWN_HOSTS_FILE");

        if (!string.IsNullOrWhiteSpace(knownHostsFile))
        {
            arguments.Add("-o");
            arguments.Add($"UserKnownHostsFile={knownHostsFile}");
        }

        if (!string.IsNullOrWhiteSpace(identityFile))
        {
            arguments.Add("-i");
            arguments.Add(ExpandHome(identityFile));
        }

        arguments.Add("--");
        arguments.Add($"{target.User}@{target.Ip}");
        arguments.Add(command);

        return commandRunner.RunAsync("ssh", arguments, options);
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
}
