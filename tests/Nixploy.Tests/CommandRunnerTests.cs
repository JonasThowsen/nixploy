using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class CommandRunnerTests
{
    [Fact]
    public async Task BoundsCapturedOutputAndFailsTheCommandOnOverflow()
    {
        var runner = new CommandRunner();
        var result = await runner.RunAsync(
            "/bin/sh",
            ["-c", "printf '1234567890'"] ,
            new CommandRunOptions
            {
                StreamOutput = false,
                MaxStandardOutputBytes = 5,
                MaxStandardErrorBytes = 5
            }
        );

        Assert.Equal(125, result.ExitCode);
        Assert.True(result.StdOutputTruncated);
        Assert.Equal("7890\n", result.StdOutput);
    }

    [Fact]
    public async Task TimesOutAndTerminatesTheWholeProcessTree()
    {
        var runner = new CommandRunner();
        var result = await runner.RunAsync(
            "/bin/sh",
            ["-c", "sleep 30"],
            new CommandRunOptions
            {
                StreamOutput = false,
                Timeout = TimeSpan.FromMilliseconds(50)
            }
        );

        Assert.Equal(124, result.ExitCode);
        Assert.True(result.TimedOut);
        Assert.False(result.Cancelled);
    }

    [Fact]
    public async Task HonorsCooperativeCancellation()
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));
        var runner = new CommandRunner();
        var result = await runner.RunAsync(
            "/bin/sh",
            ["-c", "sleep 30"],
            new CommandRunOptions
            {
                StreamOutput = false,
                CancellationToken = cancellation.Token
            }
        );

        Assert.Equal(130, result.ExitCode);
        Assert.True(result.Cancelled);
        Assert.False(result.TimedOut);
    }
}
