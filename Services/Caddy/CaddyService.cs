using System.Text.Json;

namespace Nixploy.Cli;

public sealed class CaddyService(IRemoteCommandRunner remoteCommandRunner) : ICaddyService
{
    private const string CaddyApi = "http://127.0.0.1:2019";
    private const string ServerName = "nixploy";

    public async Task<int?> GetActivePortAsync(string resourcePrefix, NixployTarget target)
    {
        var result = await CaddyRequestAsync(
            target,
            "GET",
            $"/id/{ProxyId(resourcePrefix)}/upstreams"
        );

        if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.StdOutput))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(result.StdOutput);

            if (document.RootElement.ValueKind != JsonValueKind.Array || document.RootElement.GetArrayLength() == 0)
            {
                return null;
            }

            var dial = document.RootElement[0].GetProperty("dial").GetString();

            if (dial is null)
            {
                return null;
            }

            var portText = dial.Split(':').LastOrDefault();
            return int.TryParse(portText, out var port) ? port : null;
        }
        catch (JsonException)
        {
            return null;
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
        var existing = await CaddyRequestAsync(target, "GET", $"/config/apps/http/servers/{ServerName}");

        if (existing.ExitCode == 0 && !IsNullJson(existing.StdOutput))
        {
            return true;
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

        var fullConfig = """
        {
          "apps": {
            "http": {
              "servers": {
                "nixploy": {
                  "listen": [":80", ":443"],
                  "routes": []
                }
              }
            }
          }
        }
        """;

        var load = await CaddyRequestAsync(target, "POST", "/load", fullConfig);

        if (load.ExitCode == 0)
        {
            return true;
        }

        Console.Error.WriteLine("Failed to initialize Caddy config. Is Caddy running with the admin API enabled?");
        Console.Error.WriteLine(load.StdError);
        Console.Error.WriteLine(load.StdOutput);
        return false;
    }

    private async Task<bool> EnsureRouteAsync(string resourcePrefix, NixployTarget target, int port)
    {
        var existing = await CaddyRequestAsync(target, "GET", $"/id/{RouteId(resourcePrefix)}");

        if (existing.ExitCode == 0 && !IsNullJson(existing.StdOutput))
        {
            return true;
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
}
