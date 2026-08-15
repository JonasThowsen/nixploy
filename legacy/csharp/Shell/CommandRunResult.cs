namespace Nixploy.Cli;

public sealed record CommandRunResult(
  int ExitCode,
  string StdOutput,
  string StdError,
  bool StdOutputTruncated = false,
  bool StdErrorTruncated = false,
  bool TimedOut = false,
  bool Cancelled = false
);

