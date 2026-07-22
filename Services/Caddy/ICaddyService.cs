namespace Nixploy.Cli;

public sealed record ActivePortResult(bool Success, int? Port);

public interface ICaddyService
{
    Task<ActivePortResult> GetActivePortAsync(string resourcePrefix, NixployTarget target);

    Task<bool> CheckHealthAsync(NixployTarget target, int port);

    Task<bool> SwitchAsync(string resourcePrefix, NixployTarget target, int port);

    Task<bool> DeleteRouteAsync(string resourcePrefix, NixployTarget target);
}
