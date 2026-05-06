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
            "-p",
            target.Port.ToString()
        };

        if (!string.IsNullOrWhiteSpace(target.IdentityFile))
        {
            arguments.Add("-i");
            arguments.Add(ExpandHome(target.IdentityFile));
        }

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
