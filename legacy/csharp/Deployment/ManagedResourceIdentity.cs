using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Nixploy.Cli;

public static partial class ManagedResourceIdentity
{
    public static string Derive(string project, string target)
    {
        var identityBytes = Encoding.UTF8.GetBytes($"{project}\0{target}");
        var identity = Convert.ToHexString(SHA256.HashData(identityBytes))[..10].ToLowerInvariant();
        return $"nixploy-{Sanitize(project)}-{identity}-{Sanitize(target)}";
    }

    private static string Sanitize(string value)
    {
        var sanitized = UnsafeCharacters().Replace(value.ToLowerInvariant(), "-").Trim('-');
        return sanitized.Length <= 48 ? sanitized : sanitized[..48];
    }

    [GeneratedRegex("[^a-z0-9_-]+", RegexOptions.CultureInvariant)]
    private static partial Regex UnsafeCharacters();
}
