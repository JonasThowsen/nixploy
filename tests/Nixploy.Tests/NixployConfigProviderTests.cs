using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class NixployConfigProviderTests
{
    [Fact]
    public async Task GetConfigAsync_AcceptsV02AndDefaultsReadOnlyBindsEmpty()
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

        Assert.Equal("v0.2", config.Schema);
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

        Assert.Equal("v0.3", config.Schema);
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
    [InlineData("{ \"source\": \"/srv/data\\u007fother\", \"destination\": \"/app/data\" }")]
    [InlineData("{ \"source\": \"/srv/data\\u0085other\", \"destination\": \"/app/data\" }")]
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
    public async Task GetConfigAsync_RejectsReadOnlyBindsInV02()
    {
        var provider = ProviderWithReadOnlyBinds(
            """
            [{ "source": "/srv/data", "destination": "/app/data" }]
            """,
            "v0.2"
        );

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => provider.GetConfigAsync()
        );

        Assert.Contains("Schema 'v0.2' cannot represent run.readOnlyBinds", exception.Message);
        Assert.Contains("Use schema 'v0.3'", exception.Message);
    }

    [Theory]
    [InlineData("v0.1")]
    [InlineData("v0.4")]
    public async Task GetConfigAsync_RejectsSchemasOutsideExactSupportedVersions(string schema)
    {
        var provider = ProviderWithJson($$"""
        { "__schema": "{{schema}}", "project": "my-app", "targets": {} }
        """);

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => provider.GetConfigAsync()
        );

        Assert.Contains($"Unsupported nixploy schema '{schema}'", exception.Message);
        Assert.Contains("Expected 'v0.2' or 'v0.3'", exception.Message);
    }

    public static TheoryData<string> UnknownMemberConfigs => new()
    {
        """{ "__schema": "v0.3", "project": "app", "targets": {}, "unknown": true }""",
        """{ "__schema": "v0.3", "project": "app", "targets": { "prod": { "image": "docker", "ip": "host", "unknown": true } } }""",
        """{ "__schema": "v0.3", "project": "app", "targets": { "prod": { "image": "docker", "ip": "host", "run": { "unknown": true } } } }""",
        """{ "__schema": "v0.3", "project": "app", "targets": { "prod": { "image": "docker", "ip": "host", "web": { "domain": "app.example", "unknown": true } } } }""",
        """{ "__schema": "v0.3", "project": "app", "targets": { "prod": { "image": "docker", "ip": "host", "web": { "domain": "app.example", "slots": { "unknown": true } } } } }""",
        """{ "__schema": "v0.3", "project": "app", "targets": { "prod": { "image": "docker", "ip": "host", "run": { "readOnlyBinds": [{ "source": "/srv/data", "destination": "/app/data", "unknown": true }] } } } }"""
    };

    [Theory]
    [MemberData(nameof(UnknownMemberConfigs))]
    public async Task GetConfigAsync_RejectsUnknownMembersBeforeDeployment(string json)
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, json, ""));
        var provider = new NixployConfigProvider(runner);

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => provider.GetConfigAsync()
        );

        Assert.Equal("Failed to parse .#nixploy JSON.", exception.Message);
        var call = Assert.Single(runner.Calls);
        Assert.Equal("nix", call.FileName);
        Assert.Equal(["eval", ".#nixploy", "--json"], call.Arguments);
    }

    [Fact]
    public async Task GetConfigAsync_PreservesIntentionalSecretLabelMapOnlyForStringValues()
    {
        var validProvider = ProviderWithJson("""
        {
          "__schema": "v0.2",
          "project": "app",
          "targets": {
            "prod": {
              "image": "docker",
              "ip": "host",
              "secrets": { "user-defined-label": "/secrets/app.env" }
            }
          }
        }
        """);
        var invalidProvider = ProviderWithJson("""
        {
          "__schema": "v0.2",
          "project": "app",
          "targets": {
            "prod": {
              "image": "docker",
              "ip": "host",
              "secrets": {
                "user-defined-label": { "path": "/secrets/app.env", "unknown": true }
              }
            }
          }
        }
        """);

        var config = await validProvider.GetConfigAsync();
        await Assert.ThrowsAsync<InvalidOperationException>(
            () => invalidProvider.GetConfigAsync()
        );

        Assert.Equal("/secrets/app.env", config.Targets["prod"].Secrets["user-defined-label"]);
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

    private static NixployConfigProvider ProviderWithReadOnlyBinds(
        string readOnlyBinds,
        string schema = "v0.3"
    )
    {
        return ProviderWithJson($$"""
        {
          "__schema": "{{schema}}",
          "project": "my-app",
          "targets": {
            "prod": {
              "image": "docker",
              "ip": "203.0.113.10",
              "run": { "readOnlyBinds": {{readOnlyBinds}} }
            }
          }
        }
        """);
    }

    private static NixployConfigProvider ProviderWithJson(string json)
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, json, ""));
        return new NixployConfigProvider(runner);
    }
}
