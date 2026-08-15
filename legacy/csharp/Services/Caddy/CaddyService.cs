using System.Text.Json;

namespace Nixploy.Cli;

public sealed class CaddyService(IRemoteCommandRunner remoteCommandRunner) : ICaddyService
{
    private const string CaddyApi = "http://127.0.0.1:2019";
    private const string ServerName = "nixploy";

    public async Task<ActivePortResult> GetActivePortAsync(string resourcePrefix, NixployTarget target)
    {
        var response = await GetCaddyConfigAsync(target, $"/id/{ProxyId(resourcePrefix)}/upstreams");

        if (response is null)
        {
            return new ActivePortResult(false, null);
        }

        if (response.StatusCode == 404 ||
            (response.StatusCode == 200 && IsNullJson(response.Body)))
        {
            return new ActivePortResult(true, null);
        }

        if (response.StatusCode != 200)
        {
            Console.Error.WriteLine($"Failed to inspect active Caddy upstream (HTTP {response.StatusCode}).");
            Console.Error.WriteLine(response.Body);
            return new ActivePortResult(false, null);
        }

        try
        {
            using var document = JsonDocument.Parse(response.Body);

            if (document.RootElement.ValueKind != JsonValueKind.Array || document.RootElement.GetArrayLength() == 0)
            {
                Console.Error.WriteLine("Caddy active upstream response was empty or malformed.");
                return new ActivePortResult(false, null);
            }

            var dial = document.RootElement[0].GetProperty("dial").GetString();
            var portText = dial?.Split(':').LastOrDefault();

            return int.TryParse(portText, out var port)
                ? new ActivePortResult(true, port)
                : new ActivePortResult(false, null);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            Console.Error.WriteLine("Caddy active upstream response was malformed.");
            Console.Error.WriteLine(exception.Message);
            return new ActivePortResult(false, null);
        }
    }

    public async Task<bool> CheckHealthAsync(NixployTarget target, int port)
    {
        var path = target.Web?.HealthPath ?? "/health";
        var url = $"http://127.0.0.1:{port}{path}";

        Console.WriteLine($"Checking health at {url}...");

        for (var attempt = 1; attempt <= 20; attempt++)
        {
            var result = await remoteCommandRunner.RunAsync(
                target,
                $"curl -fsS --max-time 2 {ShellQuote(url)}",
                new CommandRunOptions { StreamOutput = false }
            );

            if (result.ExitCode == 0)
            {
                Console.WriteLine("Health check passed.");
                return true;
            }

            await Task.Delay(TimeSpan.FromSeconds(1));
        }

        Console.Error.WriteLine($"Health check failed for {url}.");
        return false;
    }

    public async Task<bool> SwitchAsync(string resourcePrefix, NixployTarget target, int port)
    {
        if (target.Web is null)
        {
            return true;
        }

        if (!await EnsureServerAsync(target))
        {
            return false;
        }

        var route = await EnsureRouteAsync(resourcePrefix, target, port);
        if (!route.Success)
        {
            return false;
        }

        if (route.Created)
        {
            Console.WriteLine("Caddy route was created directly at the selected upstream.");
            return true;
        }

        Console.WriteLine($"Switching Caddy route for {target.Web.Domain} to 127.0.0.1:{port}...");

        var upstreamsJson = JsonSerializer.Serialize(new[]
        {
            new Dictionary<string, string>
            {
                ["dial"] = $"127.0.0.1:{port}"
            }
        });

        var result = await CaddyRequestAsync(
            target,
            "PATCH",
            $"/id/{ProxyId(resourcePrefix)}/upstreams",
            upstreamsJson
        );

        if (result.ExitCode == 0)
        {
            Console.WriteLine("Caddy route switched successfully.");
            return true;
        }

        Console.Error.WriteLine("Failed to switch Caddy route.");
        Console.Error.WriteLine(result.StdError);
        Console.Error.WriteLine(result.StdOutput);
        return false;
    }

    public async Task<bool> DeleteRouteAsync(string resourcePrefix, NixployTarget target)
    {
        var result = await CaddyRequestAsync(target, "DELETE", $"/id/{RouteId(resourcePrefix)}");

        if (result.ExitCode == 0)
        {
            Console.WriteLine($"Deleted Caddy route '{RouteId(resourcePrefix)}'.");
            return true;
        }

        Console.Error.WriteLine($"Failed to delete Caddy route '{RouteId(resourcePrefix)}'. It may not exist.");
        Console.Error.WriteLine(result.StdError);
        Console.Error.WriteLine(result.StdOutput);
        return false;
    }

    private async Task<bool> EnsureServerAsync(NixployTarget target)
    {
        var existing = await GetCaddyConfigAsync(target, $"/config/apps/http/servers/{ServerName}");

        if (existing is null)
        {
            return false;
        }

        if (existing.StatusCode == 200 && !IsNullJson(existing.Body))
        {
            return true;
        }

        if (existing.StatusCode != 404 &&
            !(existing.StatusCode == 200 && IsNullJson(existing.Body)))
        {
            Console.Error.WriteLine($"Failed to inspect the nixploy Caddy server (HTTP {existing.StatusCode}).");
            Console.Error.WriteLine(existing.Body);
            return false;
        }

        Console.WriteLine("Creating nixploy Caddy server config...");

        var serverJson = """
        {
          "listen": [":80", ":443"],
          "routes": []
        }
        """;

        var putServer = await CaddyRequestAsync(
            target,
            "PUT",
            $"/config/apps/http/servers/{ServerName}",
            serverJson
        );

        if (putServer.ExitCode == 0)
        {
            return true;
        }

        Console.Error.WriteLine("Failed to create the isolated nixploy Caddy server. Is the admin API enabled?");
        Console.Error.WriteLine(putServer.StdError);
        Console.Error.WriteLine(putServer.StdOutput);
        return false;
    }

    private async Task<RoutePreparationResult> EnsureRouteAsync(
        string resourcePrefix,
        NixployTarget target,
        int port
    )
    {
        var routeId = RouteId(resourcePrefix);
        var existing = await GetCaddyConfigAsync(target, $"/id/{routeId}");

        if (existing is null)
        {
            return new RoutePreparationResult(false, false);
        }

        if (existing.StatusCode == 200 && !IsNullJson(existing.Body))
        {
            if (RouteMatchesManagedShape(existing.Body, resourcePrefix, target.Web!.Domain))
            {
                return new RoutePreparationResult(true, false);
            }

            Console.Error.WriteLine(
                $"Caddy route '{routeId}' exists but does not exactly match the managed route identity and hostname."
            );
            Console.Error.WriteLine("Refusing to repair or mutate an ambiguously owned route.");
            return new RoutePreparationResult(false, false);
        }

        if (existing.StatusCode != 404 && !(existing.StatusCode == 200 && IsNullJson(existing.Body)))
        {
            Console.Error.WriteLine($"Failed to inspect Caddy route '{routeId}' (HTTP {existing.StatusCode}).");
            Console.Error.WriteLine(existing.Body);
            return new RoutePreparationResult(false, false);
        }

        Console.WriteLine($"Creating Caddy route for {target.Web!.Domain}...");

        var route = new
        {
            __id = RouteId(resourcePrefix),
            match = new[]
            {
                new
                {
                    host = new[] { target.Web.Domain }
                }
            },
            handle = new object[]
            {
                new
                {
                    handler = "subroute",
                    routes = new object[]
                    {
                        new
                        {
                            handle = new object[]
                            {
                                new
                                {
                                    __id = ProxyId(resourcePrefix),
                                    handler = "reverse_proxy",
                                    upstreams = new[]
                                    {
                                        new
                                        {
                                            dial = $"127.0.0.1:{port}"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            terminal = true
        };

        var json = JsonSerializer.Serialize(route).Replace("__id", "@id");

        var result = await CaddyRequestAsync(
            target,
            "POST",
            $"/config/apps/http/servers/{ServerName}/routes",
            json
        );

        if (result.ExitCode == 0)
        {
            return new RoutePreparationResult(true, true);
        }

        Console.Error.WriteLine($"Failed to create Caddy route for {target.Web.Domain}.");
        Console.Error.WriteLine(result.StdError);
        Console.Error.WriteLine(result.StdOutput);
        return new RoutePreparationResult(false, false);
    }

    private async Task<CaddyGetResponse?> GetCaddyConfigAsync(NixployTarget target, string path)
    {
        var command = $"curl -sS -X GET --write-out '\\n%{{http_code}}' {ShellQuote(CaddyApi + path)}";
        var result = await remoteCommandRunner.RunAsync(
            target,
            command,
            new CommandRunOptions { StreamOutput = false }
        );

        if (result.ExitCode != 0)
        {
            Console.Error.WriteLine($"Failed to query Caddy config at '{path}'.");
            Console.Error.WriteLine(result.StdError);
            Console.Error.WriteLine(result.StdOutput);
            return null;
        }

        // CommandRunner reads output line by line and restores a trailing newline, so remove
        // line endings before splitting curl's response body from its status-code trailer.
        var response = result.StdOutput.TrimEnd('\r', '\n');
        var statusSeparator = response.LastIndexOf('\n');

        if (statusSeparator < 0 ||
            !int.TryParse(response[(statusSeparator + 1)..].Trim(), out var statusCode))
        {
            Console.Error.WriteLine($"Caddy returned an invalid response while querying '{path}'.");
            Console.Error.WriteLine(result.StdOutput);
            return null;
        }

        return new CaddyGetResponse(statusCode, response[..statusSeparator]);
    }

    private static bool RouteMatchesManagedShape(
        string routeJson,
        string resourcePrefix,
        string domain
    )
    {
        try
        {
            using var document = JsonDocument.Parse(routeJson);
            var route = document.RootElement;

            if (!StringPropertyEquals(route, "@id", RouteId(resourcePrefix)) ||
                !route.TryGetProperty("terminal", out var terminal) ||
                terminal.ValueKind != JsonValueKind.True ||
                !route.TryGetProperty("match", out var match) ||
                match.ValueKind != JsonValueKind.Array ||
                match.GetArrayLength() != 1 ||
                !match[0].TryGetProperty("host", out var hosts) ||
                hosts.ValueKind != JsonValueKind.Array ||
                hosts.GetArrayLength() != 1 ||
                !string.Equals(hosts[0].GetString(), domain, StringComparison.OrdinalIgnoreCase) ||
                !route.TryGetProperty("handle", out var handles) ||
                handles.ValueKind != JsonValueKind.Array ||
                handles.GetArrayLength() != 1 ||
                !StringPropertyEquals(handles[0], "handler", "subroute") ||
                !handles[0].TryGetProperty("routes", out var routes) ||
                routes.ValueKind != JsonValueKind.Array ||
                routes.GetArrayLength() != 1 ||
                !routes[0].TryGetProperty("handle", out var proxyHandles) ||
                proxyHandles.ValueKind != JsonValueKind.Array ||
                proxyHandles.GetArrayLength() != 1)
            {
                return false;
            }

            var proxy = proxyHandles[0];
            return StringPropertyEquals(proxy, "@id", ProxyId(resourcePrefix)) &&
                StringPropertyEquals(proxy, "handler", "reverse_proxy");
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException)
        {
            return false;
        }
    }

    private static bool StringPropertyEquals(JsonElement element, string property, string expected)
    {
        return element.TryGetProperty(property, out var value) &&
            value.ValueKind == JsonValueKind.String &&
            string.Equals(value.GetString(), expected, StringComparison.Ordinal);
    }

    private static bool IsNullJson(string output)
    {
        return string.Equals(output.Trim(), "null", StringComparison.OrdinalIgnoreCase);
    }

    private Task<CommandRunResult> CaddyRequestAsync(
        NixployTarget target,
        string method,
        string path,
        string? body = null
    )
    {
        var command = body is null
            ? $"curl -fsS -X {method} {ShellQuote(CaddyApi + path)}"
            : $"curl -fsS -X {method} -H 'Content-Type: application/json' --data-binary @- {ShellQuote(CaddyApi + path)}";

        return remoteCommandRunner.RunAsync(
            target,
            command,
            new CommandRunOptions
            {
                StreamOutput = false,
                StandardInput = body
            }
        );
    }

    private static string RouteId(string targetName)
    {
        return $"nixploy-route-{SanitizeId(targetName)}";
    }

    private static string ProxyId(string targetName)
    {
        return $"nixploy-proxy-{SanitizeId(targetName)}";
    }

    private static string SanitizeId(string value)
    {
        return string.Concat(value.Select(character =>
            char.IsLetterOrDigit(character) || character is '-' or '_'
                ? character
                : '-'
        ));
    }

    private static string ShellQuote(string value)
    {
        return "'" + value.Replace("'", "'\\''") + "'";
    }

    private sealed record CaddyGetResponse(int StatusCode, string Body);
    private sealed record RoutePreparationResult(bool Success, bool Created);
}
