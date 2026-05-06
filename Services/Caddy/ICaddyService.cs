namespace Nixploy.Cli;

public interface ICaddyService
{
    Task<int?> GetActivePortAsync(string resourcePrefix, NixployTarget target);

    Task<bool> CheckHealthAsync(NixployTarget target, int port);

    Task<bool> SwitchAsync(string resourcePrefix, NixployTarget target, int port);

    Task<bool> DeleteRouteAsync(string resourcePrefix, NixployTarget target);
}
