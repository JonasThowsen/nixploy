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
    public async Task StreamsSensitiveOutputToFileWithoutRetainingOutputOrError()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"nixploy-runner-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, "identity");
        Directory.CreateDirectory(directory);
        await File.WriteAllTextAsync(path, "", TestContext.Current.CancellationToken);

        try
        {
            var runner = new CommandRunner();
            var result = await runner.RunAsync(
                "/bin/sh",
                ["-c", "printf secret-output; printf secret-error >&2"],
                new CommandRunOptions
                {
                    StreamOutput = false,
                    StandardOutputFile = path,
                    RetainStandardError = false
                }
            );

            Assert.Equal(0, result.ExitCode);
            Assert.Equal("", result.StdOutput);
            Assert.Equal("", result.StdError);
            Assert.Equal("secret-output", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task BoundsSensitiveFileOutputAndFailsOnOverflow()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"nixploy-runner-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, "identity");
        Directory.CreateDirectory(directory);
        await File.WriteAllTextAsync(path, "", TestContext.Current.CancellationToken);

        try
        {
            var runner = new CommandRunner();
            var result = await runner.RunAsync(
                "/bin/sh",
                ["-c", "printf 1234567890"],
                new CommandRunOptions
                {
                    StreamOutput = false,
                    StandardOutputFile = path,
                    MaxStandardOutputBytes = 5
                }
            );

            Assert.Equal(125, result.ExitCode);
            Assert.True(result.StdOutputTruncated);
            Assert.Equal("", result.StdOutput);
            Assert.Equal("12345", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task AppliesAndRemovesExplicitEnvironmentVariables()
    {
        const string inheritedName = "NIXPLOY_RUNNER_INHERITED_TEST";
        var previous = Environment.GetEnvironmentVariable(inheritedName);
        Environment.SetEnvironmentVariable(inheritedName, "must-be-removed");

        try
        {
            var runner = new CommandRunner();
            var result = await runner.RunAsync(
                "/bin/sh",
                ["-c", $"printf '%s:%s' \"$NIXPLOY_RUNNER_EXPLICIT_TEST\" \"${inheritedName}\""],
                new CommandRunOptions
                {
                    StreamOutput = false,
                    EnvironmentVariables = new Dictionary<string, string?>
                    {
                        ["NIXPLOY_RUNNER_EXPLICIT_TEST"] = "present",
                        [inheritedName] = null
                    }
                }
            );

            Assert.Equal(0, result.ExitCode);
            Assert.Equal("present:\n", result.StdOutput);
        }
        finally
        {
            Environment.SetEnvironmentVariable(inheritedName, previous);
        }
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
