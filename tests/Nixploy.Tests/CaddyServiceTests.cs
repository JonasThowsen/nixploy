using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class CaddyServiceTests
{
    [Fact]
    public async Task GetActivePortAsync_ReturnsPortFromCurrentUpstream()
    {
        var runner = new RecordingRemoteCommandRunner(new CommandRunResult(0, """
        [{"dial":"127.0.0.1:8081"}]
        """, ""));
        var service = new CaddyService(runner);

        var port = await service.GetActivePortAsync("nixploy-my-app-prod", new NixployTarget());

        Assert.Equal(8081, port);
        Assert.Contains("/id/nixploy-proxy-nixploy-my-app-prod/upstreams", runner.Calls[0].Command);
    }

    [Fact]
    public async Task GetActivePortAsync_ReturnsNullForMissingRoute()
    {
        var runner = new RecordingRemoteCommandRunner(new CommandRunResult(22, "", "not found"));
        var service = new CaddyService(runner);

        var port = await service.GetActivePortAsync("nixploy-my-app-prod", new NixployTarget());

        Assert.Null(port);
    }

    [Fact]
    public async Task SwitchAsync_CreatesRouteAndPatchesUpstream()
    {
        var runner = new RecordingRemoteCommandRunner(
            new CommandRunResult(0, "{}", ""),
            new CommandRunResult(22, "null", ""),
            new CommandRunResult(0, "", ""),
            new CommandRunResult(0, "", "")
        );
        var service = new CaddyService(runner);
        var target = new NixployTarget
        {
            Web = new NixployWebConfig { Domain = "app.example.com" }
        };

        var success = await service.SwitchAsync("nixploy-my-app-prod", target, 8080);

        Assert.True(success);
        Assert.Contains(runner.Calls, call => call.Command.Contains("/config/apps/http/servers/nixploy/routes"));
        Assert.Contains(runner.Calls, call => call.Command.Contains("/id/nixploy-proxy-nixploy-my-app-prod/upstreams"));
        Assert.Contains(runner.Calls, call => call.Options?.StandardInput?.Contains("app.example.com") == true);
        Assert.Contains(runner.Calls, call => call.Options?.StandardInput?.Contains("127.0.0.1:8080") == true);
    }

    [Fact]
    public async Task DeleteRouteAsync_DeletesProjectScopedRoute()
    {
        var runner = new RecordingRemoteCommandRunner(new CommandRunResult(0, "", ""));
        var service = new CaddyService(runner);

        var success = await service.DeleteRouteAsync("nixploy-my-app-prod", new NixployTarget());

        Assert.True(success);
        Assert.Contains("-X DELETE", runner.Calls[0].Command);
        Assert.Contains("/id/nixploy-route-nixploy-my-app-prod", runner.Calls[0].Command);
    }

    private sealed class RecordingRemoteCommandRunner(params CommandRunResult[] results) : IRemoteCommandRunner
    {
        private readonly Queue<CommandRunResult> results = new(results);

        public List<RemoteCommandCall> Calls { get; } = [];

        public Task<CommandRunResult> RunAsync(
            NixployTarget target,
            string command,
            CommandRunOptions? options = null
        )
        {
            Calls.Add(new RemoteCommandCall(target, command, options));
            return Task.FromResult(results.Count > 1 ? results.Dequeue() : results.Peek());
        }
    }

    private sealed record RemoteCommandCall(
        NixployTarget Target,
        string Command,
        CommandRunOptions? Options
    );
}
