namespace Nixploy.Cli;

public interface ICommandRunner
{
    Task<CommandRunResult> RunAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        CommandRunOptions? options = null
    );
}
