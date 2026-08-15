using System.Text.Json;
using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class DeploymentReporterTests
{
    [Fact]
    public void EmitsOrderedJsonLinesAndExactlyOneTerminalEvent()
    {
        using var output = new StringWriter();
        using (var reporter = DeploymentReporter.CreateForProtocol(output, "operation-1"))
        {
            reporter.Stage("building", "Building immutable source");
            reporter.Succeed("Verified", new Dictionary<string, object?> { ["resource_key"] = "nixploy-app-key-target" });
        }

        var lines = output.ToString().Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(2, lines.Length);

        using var first = JsonDocument.Parse(lines[0]);
        using var terminal = JsonDocument.Parse(lines[1]);
        Assert.Equal("nixploy.event/v1", first.RootElement.GetProperty("schema").GetString());
        Assert.Equal(1, first.RootElement.GetProperty("seq").GetInt32());
        Assert.Equal("building", first.RootElement.GetProperty("stage").GetString());
        Assert.Equal(2, terminal.RootElement.GetProperty("seq").GetInt32());
        Assert.Equal("terminal", terminal.RootElement.GetProperty("type").GetString());
        Assert.Equal("succeeded", terminal.RootElement.GetProperty("status").GetString());
    }

    [Fact]
    public void DisposeEmitsOneBoundedFailureWhenNoTerminalWasReported()
    {
        using var output = new StringWriter();
        using (var reporter = DeploymentReporter.CreateForProtocol(output, "operation-2"))
        {
            reporter.Stage("preparing", "Preparing");
        }

        var lines = output.ToString().Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(2, lines.Length);
        using var terminal = JsonDocument.Parse(lines[1]);
        Assert.Equal("failed", terminal.RootElement.GetProperty("stage").GetString());
        Assert.Equal("remote_cli_failed", terminal.RootElement.GetProperty("code").GetString());
    }

    [Fact]
    public void RejectsProtocolOutputBeyondTheLineBound()
    {
        using var output = new StringWriter();
        using var reporter = DeploymentReporter.CreateForProtocol(output, "operation-3");

        Assert.Throws<InvalidOperationException>(() =>
            reporter.Stage("building", new string('x', DeploymentReporter.MaxLineBytes))
        );
    }
}
