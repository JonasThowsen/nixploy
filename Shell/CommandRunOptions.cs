namespace Nixploy.Cli;

public sealed class CommandRunOptions
{
    public bool StreamOutput { get; init; } = true;

    public string? StandardInput { get; init; }

    public bool Interactive { get; init; }
}
