using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class PodmanServiceTests
{
    [Fact]
    public void GetConnectionName_ReturnsResourcePrefix()
    {
        var service = new PodmanService(new RecordingCommandRunner());

        var connectionName = service.GetConnectionName("nixploy-my-app-abc123-prod");

        Assert.Equal("nixploy-my-app-abc123-prod", connectionName);
    }

    [Fact]
    public async Task RunImageAsync_AddsDeploymentLabels()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, "", ""));
        var service = new PodmanService(runner);
        var metadata = new DeploymentMetadata(
            "my-app",
            "abc123",
            "production",
            "https://github.com/example/my-app",
            "deadbeefcafe",
            "2026-05-06T12:00:00.0000000+00:00"
        );

        var success = await service.RunImageAsync(
            "nixploy-my-app-abc123-production",
            "nixploy-my-app-abc123-production",
            "localhost/my-image:latest",
            new NixployRunConfig(),
            null,
            [],
            metadata
        );

        Assert.True(success);

        var run = Assert.Single(runner.Calls, call => call.Arguments.Contains("run"));
        Assert.Contains("nixploy.project=my-app", run.Arguments);
        Assert.Contains("nixploy.project_id=abc123", run.Arguments);
        Assert.Contains("nixploy.target=production", run.Arguments);
        Assert.Contains("nixploy.repository=https://github.com/example/my-app", run.Arguments);
        Assert.Contains("nixploy.git_commit=deadbeefcafe", run.Arguments);
        Assert.Contains("nixploy.deployed_at=2026-05-06T12:00:00.0000000+00:00", run.Arguments);
        Assert.Contains("io.nixploy.managed=true", run.Arguments);
        Assert.Contains("io.nixploy.repository=https://github.com/example/my-app", run.Arguments);
        Assert.Contains("org.opencontainers.image.source=https://github.com/example/my-app", run.Arguments);
        Assert.Contains("org.opencontainers.image.revision=deadbeefcafe", run.Arguments);
    }

    [Fact]
    public async Task EnsureConnectionAsync_FailsWhenStrictSshPreflightFails()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(255, "", "host key verification failed"));
        var service = new PodmanService(runner);
        var target = new NixployTarget { Ip = "203.0.113.10", User = "deploy", Port = 22 };

        var success = await service.EnsureConnectionAsync("nixploy-my-app-prod", "prod", target);

        Assert.False(success);
        var call = Assert.Single(runner.Calls);
        Assert.Equal("ssh", call.FileName);
        Assert.Contains("StrictHostKeyChecking=yes", call.Arguments);
    }

    [Fact]
    public async Task EnsureConnectionAsync_CreatesAndVerifiesMissingConnection()
    {
        var runner = new RecordingCommandRunner(
            new CommandRunResult(0, "", ""),
            new CommandRunResult(0, "[]", ""),
            new CommandRunResult(1, "", "missing"),
            new CommandRunResult(0, "", ""),
            new CommandRunResult(0, "", "")
        );
        var service = new PodmanService(runner);
        var target = new NixployTarget
        {
            Ip = "203.0.113.10",
            User = "deploy",
            Port = 2222,
            IdentityFile = "/tmp/id_ed25519"
        };

        var success = await service.EnsureConnectionAsync("nixploy-my-app-prod", "prod", target);

        Assert.True(success);
        Assert.Equal("ssh", runner.Calls[0].FileName);
        Assert.Contains("StrictHostKeyChecking=yes", runner.Calls[0].Arguments);
        Assert.Equal(["system", "connection", "list", "--format", "json"], runner.Calls[1].Arguments);
        Assert.Equal("info", runner.Calls[2].Arguments[^1]);
        Assert.Equal(
            ["system", "connection", "add", "nixploy-my-app-prod", "--port", "2222", "deploy@203.0.113.10"],
            runner.Calls[3].Arguments
        );
        Assert.Equal("info", runner.Calls[4].Arguments[^1]);
    }

    [Fact]
    public async Task EnsureConnectionAsync_RecreatesExistingConnectionWithStoredIdentity()
    {
        var runner = new RecordingCommandRunner(
            new CommandRunResult(0, "", ""),
            new CommandRunResult(0, """
            [{"Name":"nixploy-my-app-prod","Identity":"/tmp/id_ed25519"}]
            """, ""),
            new CommandRunResult(0, "", ""),
            new CommandRunResult(1, "", "missing"),
            new CommandRunResult(0, "", ""),
            new CommandRunResult(0, "", "")
        );
        var service = new PodmanService(runner);
        var target = new NixployTarget
        {
            Ip = "203.0.113.10",
            User = "deploy",
            Port = 2222,
            IdentityFile = "/tmp/id_ed25519"
        };

        var success = await service.EnsureConnectionAsync("nixploy-my-app-prod", "prod", target);

        Assert.True(success);
        Assert.Equal(["system", "connection", "rm", "nixploy-my-app-prod"], runner.Calls[2].Arguments);
        Assert.Equal(["system", "connection", "add", "nixploy-my-app-prod", "--port", "2222", "deploy@203.0.113.10"], runner.Calls[4].Arguments);
    }

    [Fact]
    public async Task EnsureConnectionAsync_UsesConnectionPointingToCurrentTarget()
    {
        var runner = new RecordingCommandRunner(
            new CommandRunResult(0, "", ""),
            new CommandRunResult(0, """
            [{"Name":"nixploy-my-app-prod","URI":"ssh://deploy@203.0.113.10:2222/run/user/1000/podman/podman.sock"}]
            """, ""),
            new CommandRunResult(0, "", "")
        );
        var service = new PodmanService(runner);
        var target = new NixployTarget
        {
            Ip = "203.0.113.10",
            User = "deploy",
            Port = 2222
        };

        var success = await service.EnsureConnectionAsync("nixploy-my-app-prod", "prod", target);

        Assert.True(success);
        Assert.Equal(3, runner.Calls.Count);
        Assert.Equal("info", runner.Calls[2].Arguments[^1]);
    }

    [Fact]
    public async Task EnsureConnectionAsync_RecreatesConnectionPointingToDifferentTarget()
    {
        var runner = new RecordingCommandRunner(
            new CommandRunResult(0, "", ""),
            new CommandRunResult(0, """
            [{"Name":"nixploy-my-app-prod","URI":"ssh://deploy@203.0.113.10:2222/run/user/1000/podman/podman.sock"}]
            """, ""),
            new CommandRunResult(0, "", ""),
            new CommandRunResult(1, "", "missing"),
            new CommandRunResult(0, "", ""),
            new CommandRunResult(0, "", "")
        );
        var service = new PodmanService(runner);
        var target = new NixployTarget
        {
            Ip = "198.51.100.20",
            User = "deploy",
            Port = 2222
        };

        var success = await service.EnsureConnectionAsync("nixploy-my-app-prod", "prod", target);

        Assert.True(success);
        Assert.Equal(["system", "connection", "rm", "nixploy-my-app-prod"], runner.Calls[2].Arguments);
        Assert.Equal(
            ["system", "connection", "add", "nixploy-my-app-prod", "--port", "2222", "deploy@198.51.100.20"],
            runner.Calls[4].Arguments
        );
    }

    [Fact]
    public async Task LoadImageAsync_ParsesLoadedImageReference()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, "Loaded image: localhost/app:latest\n", ""));
        var service = new PodmanService(runner);

        var image = await service.LoadImageAsync("connection", "result-image");

        Assert.Equal("localhost/app:latest", image?.Reference);
        Assert.Equal(["--connection", "connection", "load", "-i", "result-image"], runner.Calls[0].Arguments);
    }

    [Fact]
    public async Task InstallSecretsAsync_RecreatesSecretsWithResourcePrefix()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, "", ""));
        var service = new PodmanService(runner);

        var mounts = await service.InstallSecretsAsync(
            "connection",
            "nixploy-my-app-prod",
            [new Secret("DATABASE_URL", "postgres://localhost/app")]
        );

        Assert.Equal([new SecretMount("nixploy-my-app-prod-DATABASE_URL", "DATABASE_URL")], mounts);
        Assert.Equal(["--connection", "connection", "secret", "rm", "nixploy-my-app-prod-DATABASE_URL"], runner.Calls[0].Arguments);
        Assert.Equal(["--connection", "connection", "secret", "create", "nixploy-my-app-prod-DATABASE_URL", "-"], runner.Calls[1].Arguments);
        Assert.Equal("postgres://localhost/app", runner.Calls[1].Options?.StandardInput);
    }

    [Fact]
    public async Task PruneTargetAsync_RemovesKnownContainersAndPrefixedSecrets()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, "nixploy-my-app-prod-DATABASE_URL\nother-secret\n", ""));
        var service = new PodmanService(runner);

        var success = await service.PruneTargetAsync("connection", "nixploy-my-app-prod");

        Assert.True(success);
        Assert.Contains(runner.Calls, call => call.Arguments.SequenceEqual(["--connection", "connection", "rm", "-f", "nixploy-my-app-prod"]));
        Assert.Contains(runner.Calls, call => call.Arguments.SequenceEqual(["--connection", "connection", "rm", "-f", "nixploy-my-app-prod-blue"]));
        Assert.Contains(runner.Calls, call => call.Arguments.SequenceEqual(["--connection", "connection", "rm", "-f", "nixploy-my-app-prod-green"]));
        Assert.Contains(runner.Calls, call => call.Arguments.SequenceEqual(["--connection", "connection", "secret", "rm", "nixploy-my-app-prod-DATABASE_URL"]));
        Assert.DoesNotContain(runner.Calls, call => call.Arguments.SequenceEqual(["--connection", "connection", "secret", "rm", "other-secret"]));
    }

    [Fact]
    public async Task RunPreStartCommandsAsync_RendersPortEnvironmentAndSecrets()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, "", ""));
        var service = new PodmanService(runner);

        var success = await service.RunPreStartCommandsAsync(
            "connection",
            "localhost/app:latest",
            [["/app/migrate"]],
            "host",
            new Dictionary<string, string> { ["PORT"] = "{port}" },
            8080,
            [new SecretMount("secret-source", "SECRET_TARGET")]
        );

        Assert.True(success);
        var arguments = runner.Calls[0].Arguments;
        Assert.Contains("--rm", arguments);
        Assert.Contains("--network", arguments);
        Assert.Contains("host", arguments);
        Assert.Contains("PORT=8080", arguments);
        Assert.Contains("source=secret-source,type=env,target=SECRET_TARGET", arguments);
        Assert.Equal("/app/migrate", arguments[^1]);
    }
}
