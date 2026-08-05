using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class NixployConfigProviderTests
{
    [Fact]
    public async Task GetConfigAsync_EvaluatesNixployFlakeOutput()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, """
        {
          "__schema": "v0.2",
          "project": "my-app",
          "targets": {
            "prod": {
              "image": "docker",
              "ip": "203.0.113.10"
            }
          }
        }
        """, ""));
        var provider = new NixployConfigProvider(runner);

        var config = await provider.GetConfigAsync("/nix/store/source");

        Assert.Equal("my-app", config.Project);
        Assert.True(config.Targets.ContainsKey("prod"));
        Assert.Equal("docker", config.Targets["prod"].Image);
        Assert.Equal("203.0.113.10", config.Targets["prod"].Ip);
        Assert.Equal("nix", runner.Calls[0].FileName);
        Assert.Equal(
            ["eval", "--json", "--no-write-lock-file", "/nix/store/source#nixploy"],
            runner.Calls[0].Arguments
        );
    }

    [Fact]
    public async Task GetConfigAsync_RejectsUnsupportedSchema()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, """
        { "__schema": "v0.1", "project": "my-app", "targets": {} }
        """, ""));
        var provider = new NixployConfigProvider(runner);

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            provider.GetConfigAsync("/nix/store/source")
        );

        Assert.Contains("Unsupported nixploy schema 'v0.1'", exception.Message);
    }

    [Fact]
    public async Task GetConfigAsync_CachesEvaluatedConfig()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, """
        { "__schema": "v0.2", "project": "my-app", "targets": {} }
        """, ""));
        var provider = new NixployConfigProvider(runner);

        _ = await provider.GetConfigAsync("/nix/store/source");
        _ = await provider.GetConfigAsync("/nix/store/source");

        Assert.Single(runner.Calls);
    }
}
