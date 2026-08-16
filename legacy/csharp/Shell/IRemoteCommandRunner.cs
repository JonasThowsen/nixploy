namespace Nixploy.Cli;

public interface IRemoteCommandRunner
{
    Task<CommandRunResult> RunAsync(
        NixployTarget target,
        string command,
        CommandRunOptions? options = null
    );
}
