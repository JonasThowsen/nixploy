using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class CaddyServiceTests
{
    private const string ResourcePrefix = "nixploy-my-app-prod";
    private const string RouteId = "nixploy-route-nixploy-my-app-prod";
    private const string ProxyId = "nixploy-proxy-nixploy-my-app-prod";

    [Fact]
    public async Task GetActivePortAsync_ReturnsPortFromCurrentUpstream()
    {
        var runner = new RecordingRemoteCommandRunner(new CommandRunResult(0, """
        [{"dial":"127.0.0.1:8081"}]
        """, ""));
        var service = new CaddyService(runner);

        var port = await service.GetActivePortAsync(ResourcePrefix, new NixployTarget());

        Assert.Equal(8081, port);
        Assert.Contains($"/id/{ProxyId}/upstreams", runner.Calls[0].Command);
    }

    [Fact]
    public async Task GetActivePortAsync_ReturnsNullForMissingRoute()
    {
        var runner = new RecordingRemoteCommandRunner(new CommandRunResult(22, "", "not found"));
        var service = new CaddyService(runner);

        var port = await service.GetActivePortAsync(ResourcePrefix, new NixployTarget());

        Assert.Null(port);
    }

    [Fact]
    public async Task SwitchAsync_ReusesRouteWithMatchingDomain()
    {
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse(RouteJson("app.example.com")),
            Success()
        );
        var service = new CaddyService(runner);

        var success = await service.SwitchAsync(ResourcePrefix, WebTarget("app.example.com"), 8081);

        Assert.True(success);
        Assert.Equal(3, runner.Calls.Count);
        Assert.DoesNotContain(runner.Calls, call => call.Command.Contains($"/id/{RouteId}/match"));
        Assert.DoesNotContain(runner.Calls, call =>
            call.Command.Contains("/config/apps/http/servers/nixploy/routes") &&
            call.Command.Contains("-X POST")
        );
        Assert.Contains($"/id/{ProxyId}/upstreams", runner.Calls[2].Command);
    }

    [Fact]
    public async Task SwitchAsync_UpdatesStaleDomainBeforeSwitchingUpstream()
    {
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse(RouteJson("old.example.com")),
            Success(),
            Success()
        );
        var service = new CaddyService(runner);

        var success = await service.SwitchAsync(ResourcePrefix, WebTarget("new.example.com"), 8081);

        Assert.True(success);
        Assert.Equal(4, runner.Calls.Count);

        var matcherUpdate = runner.Calls[2];
        Assert.Contains($"/id/{RouteId}/match", matcherUpdate.Command);
        Assert.Contains("-X PATCH", matcherUpdate.Command);
        Assert.Contains("new.example.com", matcherUpdate.Options?.StandardInput);
        Assert.DoesNotContain("old.example.com", matcherUpdate.Options?.StandardInput);

        var upstreamUpdate = runner.Calls[3];
        Assert.Contains($"/id/{ProxyId}/upstreams", upstreamUpdate.Command);
        Assert.Contains("127.0.0.1:8081", upstreamUpdate.Options?.StandardInput);
    }

    [Fact]
    public async Task SwitchAsync_RepairsMalformedHostMatcher()
    {
        var malformedRoute = $$"""
        {
          "@id": "{{RouteId}}",
          "match": [{"path":["/*"]}]
        }
        """;
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse(malformedRoute),
            Success(),
            Success()
        );
        var service = new CaddyService(runner);

        var success = await service.SwitchAsync(ResourcePrefix, WebTarget("app.example.com"), 8080);

        Assert.True(success);
        Assert.Contains($"/id/{RouteId}/match", runner.Calls[2].Command);
        Assert.Contains("app.example.com", runner.Calls[2].Options?.StandardInput);
    }

    [Fact]
    public async Task SwitchAsync_CreatesMissingRouteAndPatchesUpstream()
    {
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse("", 404),
            Success(),
            Success()
        );
        var service = new CaddyService(runner);

        var success = await service.SwitchAsync(ResourcePrefix, WebTarget("app.example.com"), 8080);

        Assert.True(success);
        Assert.Contains(runner.Calls, call =>
            call.Command.Contains("/config/apps/http/servers/nixploy/routes") &&
            call.Command.Contains("-X POST")
        );
        Assert.Contains(runner.Calls, call => call.Command.Contains($"/id/{ProxyId}/upstreams"));
        Assert.Contains(runner.Calls, call =>
            call.Options?.StandardInput?.Contains("app.example.com") == true
        );
        Assert.Contains(runner.Calls, call =>
            call.Options?.StandardInput?.Contains("127.0.0.1:8080") == true
        );
    }

    [Fact]
    public async Task SwitchAsync_AbortsWhenRouteInspectionFails()
    {
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse("internal error", 500)
        );
        var service = new CaddyService(runner);

        var success = await service.SwitchAsync(ResourcePrefix, WebTarget("app.example.com"), 8080);

        Assert.False(success);
        Assert.Equal(2, runner.Calls.Count);
        Assert.DoesNotContain(runner.Calls, call => call.Command.Contains($"/id/{ProxyId}/upstreams"));
    }

    [Fact]
    public async Task SwitchAsync_AbortsWhenDomainUpdateFails()
    {
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse(RouteJson("old.example.com")),
            new CommandRunResult(22, "", "update failed")
        );
        var service = new CaddyService(runner);

        var success = await service.SwitchAsync(ResourcePrefix, WebTarget("new.example.com"), 8080);

        Assert.False(success);
        Assert.Equal(3, runner.Calls.Count);
        Assert.DoesNotContain(runner.Calls, call => call.Command.Contains($"/id/{ProxyId}/upstreams"));
    }

    [Fact]
    public async Task SwitchAsync_ReconcilesDomainAcrossConsecutiveDeployments()
    {
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse("", 404),
            Success(),
            Success(),
            ExistingServer(),
            RouteResponse(RouteJson("old.example.com")),
            Success(),
            Success()
        );
        var service = new CaddyService(runner);

        Assert.True(await service.SwitchAsync(ResourcePrefix, WebTarget("old.example.com"), 8080));
        Assert.True(await service.SwitchAsync(ResourcePrefix, WebTarget("new.example.com"), 8081));

        Assert.Equal(8, runner.Calls.Count);
        Assert.Contains($"/id/{RouteId}/match", runner.Calls[6].Command);
        Assert.Contains("new.example.com", runner.Calls[6].Options?.StandardInput);
        Assert.Contains($"/id/{ProxyId}/upstreams", runner.Calls[7].Command);
        Assert.Contains("127.0.0.1:8081", runner.Calls[7].Options?.StandardInput);
    }

    [Fact]
    public async Task DeleteRouteAsync_DeletesProjectScopedRoute()
    {
        var runner = new RecordingRemoteCommandRunner(Success());
        var service = new CaddyService(runner);

        var success = await service.DeleteRouteAsync(ResourcePrefix, new NixployTarget());

        Assert.True(success);
        Assert.Contains("-X DELETE", runner.Calls[0].Command);
        Assert.Contains($"/id/{RouteId}", runner.Calls[0].Command);
    }

    private static NixployTarget WebTarget(string domain)
    {
        return new NixployTarget
        {
            Web = new NixployWebConfig { Domain = domain }
        };
    }

    private static CommandRunResult ExistingServer()
    {
        return new CommandRunResult(0, "{}", "");
    }

    private static CommandRunResult RouteResponse(string body, int statusCode = 200)
    {
        return new CommandRunResult(0, $"{body}\n{statusCode}{Environment.NewLine}", "");
    }

    private static CommandRunResult Success()
    {
        return new CommandRunResult(0, "", "");
    }

    private static string RouteJson(string domain)
    {
        return $$"""
        {
          "@id": "{{RouteId}}",
          "match": [{"host":["{{domain}}"]}],
          "handle": [{
            "handler": "subroute",
            "routes": [{
              "handle": [{
                "@id": "{{ProxyId}}",
                "handler": "reverse_proxy",
                "upstreams": [{"dial":"127.0.0.1:8080"}]
              }]
            }]
          }],
          "terminal": true
        }
        """;
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

            if (results.Count == 0)
            {
                throw new InvalidOperationException($"No recorded result remains for command: {command}");
            }

            return Task.FromResult(results.Dequeue());
        }
    }

    private sealed record RemoteCommandCall(
        NixployTarget Target,
        string Command,
        CommandRunOptions? Options
    );
}
