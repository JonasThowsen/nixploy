namespace Nixploy.Cli;

public sealed record TaskExecutionResult(
    bool Success,
    string Output,
    bool OutputTruncated,
    int ExitCode
);
