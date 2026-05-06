namespace Nixploy.Cli;

public sealed record CommandRunResult(
  int ExitCode,
  string StdOutput,
  string StdError
);

