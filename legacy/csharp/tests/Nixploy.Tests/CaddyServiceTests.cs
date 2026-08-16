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
        200
        """, ""));
        var service = new CaddyService(runner);

        var result = await service.GetActivePortAsync(ResourcePrefix, new NixployTarget());

        Assert.True(result.Success);
        Assert.Equal(8081, result.Port);
        Assert.Contains($"/id/{ProxyId}/upstreams", runner.Calls[0].Command);
    }

    [Fact]
    public async Task GetActivePortAsync_ReturnsNullForMissingRoute()
    {
        var runner = new RecordingRemoteCommandRunner(new CommandRunResult(0, "null\n404\n", ""));
        var service = new CaddyService(runner);

        var result = await service.GetActivePortAsync(ResourcePrefix, new NixployTarget());

        Assert.True(result.Success);
        Assert.Null(result.Port);
    }

    [Fact]
    public async Task GetActivePortAsync_FailsClosedForUnavailableCaddyState()
    {
        var runner = new RecordingRemoteCommandRunner(new CommandRunResult(7, "", "connection refused"));
        var service = new CaddyService(runner);

        var result = await service.GetActivePortAsync(ResourcePrefix, new NixployTarget());

        Assert.False(result.Success);
        Assert.Null(result.Port);
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
    public async Task SwitchAsync_RejectsRouteWithStaleDomainWithoutMutation()
    {
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse(RouteJson("old.example.com"))
        );
        var service = new CaddyService(runner);

        var success = await service.SwitchAsync(ResourcePrefix, WebTarget("new.example.com"), 8081);

        Assert.False(success);
        Assert.Equal(2, runner.Calls.Count);
        Assert.DoesNotContain(runner.Calls, call => call.Command.Contains("-X PATCH"));
    }

    [Fact]
    public async Task SwitchAsync_RejectsMalformedManagedRouteWithoutMutation()
    {
        var malformedRoute = $$"""
        {
          "@id": "{{RouteId}}",
          "match": [{"path":["/*"]}]
        }
        """;
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse(malformedRoute)
        );
        var service = new CaddyService(runner);

        var success = await service.SwitchAsync(ResourcePrefix, WebTarget("app.example.com"), 8080);

        Assert.False(success);
        Assert.Equal(2, runner.Calls.Count);
        Assert.DoesNotContain(runner.Calls, call => call.Command.Contains("-X PATCH"));
    }

    [Fact]
    public async Task SwitchAsync_CreatesMissingRouteDirectlyAtSelectedUpstream()
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
        Assert.DoesNotContain(runner.Calls, call => call.Command.Contains($"/id/{ProxyId}/upstreams"));
        Assert.Contains(runner.Calls, call =>
            call.Options?.StandardInput?.Contains("app.example.com") == true
        );
        Assert.Contains(runner.Calls, call =>
            call.Options?.StandardInput?.Contains("127.0.0.1:8080") == true
        );
    }

    [Fact]
    public async Task SwitchAsync_AbortsWhenServerInspectionFails()
    {
        var runner = new RecordingRemoteCommandRunner(
            new CommandRunResult(7, "", "connection refused")
        );
        var service = new CaddyService(runner);

        var success = await service.SwitchAsync(ResourcePrefix, WebTarget("app.example.com"), 8081);

        Assert.False(success);
        Assert.Single(runner.Calls);
        Assert.DoesNotContain(runner.Calls, call => call.Command.Contains("-X PUT"));
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
    public async Task SwitchAsync_RefusesDomainDriftAcrossConsecutiveDeployments()
    {
        var runner = new RecordingRemoteCommandRunner(
            ExistingServer(),
            RouteResponse("", 404),
            Success(),
            ExistingServer(),
            RouteResponse(RouteJson("old.example.com"))
        );
        var service = new CaddyService(runner);

        Assert.True(await service.SwitchAsync(ResourcePrefix, WebTarget("old.example.com"), 8080));
        Assert.False(await service.SwitchAsync(ResourcePrefix, WebTarget("new.example.com"), 8081));

        Assert.Equal(5, runner.Calls.Count);
        Assert.DoesNotContain(runner.Calls.Skip(3), call => call.Command.Contains("-X PATCH"));
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
        return new CommandRunResult(0, "{}\n200\n", "");
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
