namespace Nixploy.Cli;

public sealed class CommandRunOptions
{
    public bool StreamOutput { get; init; } = true;

    public string? StandardInput { get; init; }

    public string? StandardOutputFile { get; init; }

    public bool RetainStandardError { get; init; } = true;

    public IReadOnlyDictionary<string, string?> EnvironmentVariables { get; init; } =
        new Dictionary<string, string?>();

    public TimeSpan Timeout { get; init; } = TimeSpan.FromMinutes(30);

    public int MaxStandardOutputBytes { get; init; } = 1_048_576;

    public int MaxStandardErrorBytes { get; init; } = 1_048_576;

    public CancellationToken CancellationToken { get; init; }

}
