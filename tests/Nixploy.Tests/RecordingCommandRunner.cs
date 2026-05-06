using Nixploy.Cli;

namespace Nixploy.Tests;

internal sealed class RecordingCommandRunner(params CommandRunResult[] results) : ICommandRunner
{
    private readonly Queue<CommandRunResult> results = new(results.Length == 0
        ? [new CommandRunResult(0, "", "")]
        : results);

    public List<CommandCall> Calls { get; } = [];

    public Task<CommandRunResult> RunAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        CommandRunOptions? options = null
    )
    {
        Calls.Add(new CommandCall(fileName, [.. arguments], options));

        var result = results.Count > 1
            ? results.Dequeue()
            : results.Peek();

        return Task.FromResult(result);
    }
}

internal sealed record CommandCall(
    string FileName,
    IReadOnlyList<string> Arguments,
    CommandRunOptions? Options
);
