namespace Nixploy.Cli;

public sealed record RuntimeLogSnapshot(
    string Content,
    int LineCount,
    bool Truncated
);
