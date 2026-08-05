namespace Nixploy.Cli;

public sealed class CommandRunOptions
{
    public bool StreamOutput { get; init; } = true;

    public string? StandardInput { get; init; }

    public TimeSpan Timeout { get; init; } = TimeSpan.FromMinutes(30);

    public int MaxStandardOutputBytes { get; init; } = 1_048_576;

    public int MaxStandardErrorBytes { get; init; } = 1_048_576;

    public CancellationToken CancellationToken { get; init; }

}
