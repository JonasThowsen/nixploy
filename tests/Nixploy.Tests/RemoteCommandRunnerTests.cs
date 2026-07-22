using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class RemoteCommandRunnerTests
{
    [Fact]
    public async Task RunAsync_BuildsSshCommandForTarget()
    {
        var inner = new RecordingCommandRunner(new CommandRunResult(0, "ok", ""));
        var runner = new RemoteCommandRunner(inner);
        var target = new NixployTarget
        {
            Ip = "203.0.113.10",
            User = "deploy",
            Port = 2222,
            IdentityFile = "/tmp/id_ed25519"
        };
        var options = new CommandRunOptions { StreamOutput = false };

        var result = await runner.RunAsync(target, "echo hello", options);

        Assert.Equal(0, result.ExitCode);
        var call = Assert.Single(inner.Calls);
        Assert.Equal("ssh", call.FileName);
        Assert.Equal([
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
            "-p", "2222",
            "-i", "/tmp/id_ed25519",
            "--", "deploy@203.0.113.10", "echo hello"
        ], call.Arguments);
        Assert.Same(options, call.Options);
    }
}
