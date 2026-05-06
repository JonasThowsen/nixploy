using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class SopsServiceTests
{
    [Fact]
    public async Task LoadSecretsAsync_ParsesDotEnvOutput()
    {
        var runner = new RecordingCommandRunner(new CommandRunResult(0, """
        # ignored
        DATABASE_URL=postgres://localhost/app # trailing comment
        export API_KEY="abc\n123"
        SINGLE_QUOTED='literal value'
        INVALID_LINE
        """, ""));
        var service = new SopsService(runner);
        var target = new NixployTarget
        {
            Secrets = new Dictionary<string, string> { ["app"] = "secrets/prod.env" }
        };

        var secrets = await service.LoadSecretsAsync(target);

        Assert.Equal(
            [
                new Secret("DATABASE_URL", "postgres://localhost/app"),
                new Secret("API_KEY", "abc\n123"),
                new Secret("SINGLE_QUOTED", "literal value")
            ],
            secrets
        );
        Assert.Equal("sops", runner.Calls[0].FileName);
        Assert.Equal(["--decrypt", "--input-type", "dotenv", "--output-type", "dotenv", "secrets/prod.env"], runner.Calls[0].Arguments);
    }

    [Fact]
    public async Task LoadSecretsAsync_RejectsDuplicateSecretNamesAcrossFiles()
    {
        var runner = new RecordingCommandRunner(
            new CommandRunResult(0, "API_KEY=one", ""),
            new CommandRunResult(0, "API_KEY=two", "")
        );
        var service = new SopsService(runner);
        var target = new NixployTarget
        {
            Secrets = new Dictionary<string, string>
            {
                ["app"] = "app.env",
                ["database"] = "database.env"
            }
        };

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(() => service.LoadSecretsAsync(target));

        Assert.Contains("Duplicate secret 'API_KEY'", exception.Message);
    }
}
