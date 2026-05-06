namespace Nixploy.Cli;

public interface INixployConfigProvider
{
    Task<NixployConfig> GetConfigAsync();
}
