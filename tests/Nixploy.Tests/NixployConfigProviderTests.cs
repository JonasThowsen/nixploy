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

        var config = await provider.GetConfigAsync();

        Assert.Equal("my-app", config.Project);
        Assert.True(config.Targets.ContainsKey("prod"));
        Assert.Equal("docker", config.Targets["prod"].Image);
        Assert.Equal("203.0.113.10", config.Targets["prod"].Ip);
        Assert.Empty(config.Targets["prod"].Run.ReadOnlyBinds);
        Assert.Equal("nix", runner.Calls[0].FileName);
        Assert.Equal(["eval", ".#nixploy", "--json"], runner.Calls[0].Arguments);
    }

    [Fact]
    public async Task GetConfigAsync_DeserializesStructuredReadOnlyBinds()
    {
        var provider = ProviderWithReadOnlyBinds("""
        [
          { "source": "/srv/my app/data", "destination": "/app/data" },
          { "source": "/srv/config", "destination": "/app/config" }
        ]
        """);

        var config = await provider.GetConfigAsync();

        Assert.Collection(
            config.Targets["prod"].Run.ReadOnlyBinds,
            bind =>
            {
                Assert.Equal("/srv/my app/data", bind.Source);
                Assert.Equal("/app/data", bind.Destination);
            },
            bind =>
            {
                Assert.Equal("/srv/config", bind.Source);
                Assert.Equal("/app/config", bind.Destination);
            }
        );
    }

    [Theory]
    [InlineData("{ \"source\": \"\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"srv/data\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/srv//data\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/srv/./data\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/srv/../data\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/srv/data/\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/srv/data,ro=false\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/srv/data\\nother\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/srv/data\\u0000other\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/srv/data\", \"destination\": \"app/data\" }")]
    [InlineData("{ \"source\": \"/srv/data\", \"destination\": \"/app/../data\" }")]
    [InlineData("{ \"source\": \"/srv/data\", \"destination\": \"/app/data,rw\" }")]
    [InlineData("{ \"source\": \"/same\", \"destination\": \"/same\" }")]
    [InlineData("{ \"source\": \"/srv/data\", \"destination\": \"/app/data\", \"readOnly\": false }")]
    [InlineData("{ \"source\": \"/srv/data\", \"destination\": \"/app/data\", \"options\": [\"rw\"] }")]
    [InlineData("{ \"source\": \"/srv/data\", \"destination\": \"/app/data\", \"labels\": { \"x\": \"y\" } }")]
    public async Task GetConfigAsync_RejectsUnsafeOrWritableReadOnlyBinds(string bind)
    {
        var provider = ProviderWithReadOnlyBinds($"[{bind}]");

        await Assert.ThrowsAsync<InvalidOperationException>(() => provider.GetConfigAsync());
    }

    [Fact]
    public async Task GetConfigAsync_RejectsDuplicateReadOnlyBindDestinations()
    {
        var provider = ProviderWithReadOnlyBinds("""
        [
          { "source": "/srv/first", "destination": "/app/data" },
          { "source": "/srv/second", "destination": "/app/data" }
        ]
        """);

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => provider.GetConfigAsync()
        );

        Assert.Contains("duplicate read-only bind destination '/app/data'", exception.Message);
    }

    [Fact]
    public async Task GetConfigAsync_RejectsUnsupportedSchema()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, """
        { "__schema": "v0.1", "project": "my-app", "targets": {} }
        """, ""));
        var provider = new NixployConfigProvider(runner);

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(() => provider.GetConfigAsync());

        Assert.Contains("Unsupported nixploy schema 'v0.1'", exception.Message);
    }

    [Fact]
    public async Task GetConfigAsync_CachesEvaluatedConfig()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, """
        { "__schema": "v0.2", "project": "my-app", "targets": {} }
        """, ""));
        var provider = new NixployConfigProvider(runner);

        _ = await provider.GetConfigAsync();
        _ = await provider.GetConfigAsync();

        Assert.Single(runner.Calls);
    }

    private static NixployConfigProvider ProviderWithReadOnlyBinds(string readOnlyBinds)
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, $$"""
        {
          "__schema": "v0.2",
          "project": "my-app",
          "targets": {
            "prod": {
              "image": "docker",
              "ip": "203.0.113.10",
              "run": { "readOnlyBinds": {{readOnlyBinds}} }
            }
          }
        }
        """, ""));

        return new NixployConfigProvider(runner);
    }
}
