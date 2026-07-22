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

        if (!await EnsureRouteAsync(resourcePrefix, target, port))
        {
            return false;
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

    private async Task<bool> EnsureRouteAsync(string resourcePrefix, NixployTarget target, int port)
    {
        var routeId = RouteId(resourcePrefix);
        var existing = await GetCaddyConfigAsync(target, $"/id/{routeId}");

        if (existing is null)
        {
            return false;
        }

        if (existing.StatusCode == 200 && !IsNullJson(existing.Body))
        {
            if (RouteMatchesDomain(existing.Body, target.Web!.Domain))
            {
                return true;
            }

            Console.WriteLine($"Updating Caddy route hostname to {target.Web.Domain}...");

            var matchJson = JsonSerializer.Serialize(new[]
            {
                new
                {
                    host = new[] { target.Web.Domain }
                }
            });

            var update = await CaddyRequestAsync(
                target,
                "PATCH",
                $"/id/{routeId}/match",
                matchJson
            );

            if (update.ExitCode == 0)
            {
                return true;
            }

            Console.Error.WriteLine($"Failed to update Caddy route hostname to {target.Web.Domain}.");
            Console.Error.WriteLine(update.StdError);
            Console.Error.WriteLine(update.StdOutput);
            return false;
        }

        if (existing.StatusCode != 404 && !(existing.StatusCode == 200 && IsNullJson(existing.Body)))
        {
            Console.Error.WriteLine($"Failed to inspect Caddy route '{routeId}' (HTTP {existing.StatusCode}).");
            Console.Error.WriteLine(existing.Body);
            return false;
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
            return true;
        }

        Console.Error.WriteLine($"Failed to create Caddy route for {target.Web.Domain}.");
        Console.Error.WriteLine(result.StdError);
        Console.Error.WriteLine(result.StdOutput);
        return false;
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

    private static bool RouteMatchesDomain(string routeJson, string domain)
    {
        try
        {
            using var document = JsonDocument.Parse(routeJson);

            if (!document.RootElement.TryGetProperty("match", out var match) ||
                match.ValueKind != JsonValueKind.Array ||
                match.GetArrayLength() != 1)
            {
                return false;
            }

            var matcher = match[0];

            if (matcher.ValueKind != JsonValueKind.Object ||
                !matcher.TryGetProperty("host", out var hosts) ||
                hosts.ValueKind != JsonValueKind.Array ||
                hosts.GetArrayLength() != 1)
            {
                return false;
            }

            return string.Equals(
                hosts[0].GetString(),
                domain,
                StringComparison.OrdinalIgnoreCase
            );
        }
        catch (JsonException)
        {
            return false;
        }
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
}
