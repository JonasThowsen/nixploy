namespace Nixploy.Cli;

public interface ISopsService
{
    Task<IReadOnlyList<Secret>> LoadSecretsAsync(NixployTarget target);
}
