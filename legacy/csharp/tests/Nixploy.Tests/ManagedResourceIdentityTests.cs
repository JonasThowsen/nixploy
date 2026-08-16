using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class ManagedResourceIdentityTests
{
    [Theory]
    [InlineData("fixture-90295-r1", "production", "nixploy-fixture-90295-r1-22ce5117b6-production")]
    [InlineData("Salgs Oversikt", "Production EU", "nixploy-salgs-oversikt-f44116184a-production-eu")]
    public void DeriveMatchesTheHostCanonicalContract(string project, string target, string expected)
    {
        Assert.Equal(expected, ManagedResourceIdentity.Derive(project, target));
    }

    [Fact]
    public void DeriveBoundsEachSanitizedIdentityPart()
    {
        var result = ManagedResourceIdentity.Derive(new string('A', 80), new string('B', 80));

        Assert.Matches("^nixploy-a{48}-[0-9a-f]{10}-b{48}$", result);
    }
}
