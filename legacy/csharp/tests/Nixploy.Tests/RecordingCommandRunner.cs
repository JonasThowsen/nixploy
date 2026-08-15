using Nixploy.Cli;

namespace Nixploy.Tests;

internal sealed class RecordingCommandRunner(params CommandRunResult[] results) : ICommandRunner
{
    private readonly Queue<CommandRunResult> results = new(results.Length == 0
        ? [new CommandRunResult(0, "", "")]
        : results);

    public List<CommandCall> Calls { get; } = [];

    public UnixFileMode? OutputFileModeAtCall { get; private set; }

    public UnixFileMode? OutputDirectoryModeAtCall { get; private set; }

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

        if (options?.StandardOutputFile is { } outputFile)
        {
            if (!OperatingSystem.IsWindows())
            {
                OutputFileModeAtCall = File.GetUnixFileMode(outputFile);
                OutputDirectoryModeAtCall = File.GetUnixFileMode(Path.GetDirectoryName(outputFile)!);
            }

            if (result.ExitCode == 0)
            {
                File.WriteAllText(outputFile, "AGE-SECRET-KEY-1TEST\n");
            }

            result = result with
            {
                StdOutput = "",
                StdError = options.RetainStandardError ? result.StdError : ""
            };
        }

        return Task.FromResult(result);
    }
}

internal sealed record CommandCall(
    string FileName,
    IReadOnlyList<string> Arguments,
    CommandRunOptions? Options
);
