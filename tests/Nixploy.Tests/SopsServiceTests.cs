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
        using var key = PrivateAgeKeyFile();
        var service = new SopsService(runner, () => key.Name);
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
        using var key = PrivateAgeKeyFile();
        var service = new SopsService(runner, () => key.Name);
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

    [Fact]
    public async Task LoadSecretsAsync_RejectsMissingOrExposedWorkerKey()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        var runner = new RecordingCommandRunner();
        var target = new NixployTarget
        {
            Secrets = new Dictionary<string, string> { ["app"] = "secrets/prod.env" }
        };

        var missing = new SopsService(runner, () => null);
        await Assert.ThrowsAsync<InvalidOperationException>(() => missing.LoadSecretsAsync(target));

        using var exposed = PrivateAgeKeyFile();
        File.SetUnixFileMode(
            exposed.Name,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead
        );
        var exposedService = new SopsService(runner, () => exposed.Name);
        await Assert.ThrowsAsync<InvalidOperationException>(() => exposedService.LoadSecretsAsync(target));
    }

    [Fact]
    public async Task LoadSecretsAsync_AcceptsRootOwnedReadableSystemdCredentialWithGroupRead()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        const string path = "/run/credentials/nixploy-control-plane-worker.service/nixploy-sops-age-ssh-key";
        var runner = new RecordingCommandRunner(new CommandRunResult(0, "DATABASE_URL=redacted", ""));
        var service = new SopsService(
            runner,
            () => path,
            _ => Metadata(path, ownerUserId: 0, UnixFileMode.UserRead | UnixFileMode.GroupRead)
        );
        var target = new NixployTarget
        {
            Secrets = new Dictionary<string, string> { ["app"] = "secrets/prod.env" }
        };

        var secrets = await service.LoadSecretsAsync(target);

        Assert.Single(secrets);
        Assert.Single(runner.Calls);
        Assert.Equal("sops", runner.Calls[0].FileName);
    }

    [Fact]
    public async Task LoadSecretsAsync_RejectsUntrustedCredentialMetadataBeforeSops()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        const string systemdPath =
            "/run/credentials/nixploy-control-plane-worker.service/nixploy-sops-age-ssh-key";
        var cases = new[]
        {
            Metadata("/tmp/group-readable-age-key", 0, UnixFileMode.UserRead | UnixFileMode.GroupRead),
            Metadata(systemdPath, 1000, UnixFileMode.UserRead | UnixFileMode.GroupRead),
            Metadata(systemdPath, 0, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead),
            Metadata(systemdPath, 0, UnixFileMode.UserRead | UnixFileMode.GroupWrite),
            Metadata(systemdPath, 0, UnixFileMode.UserRead | UnixFileMode.GroupExecute),
            Metadata(systemdPath, 0, UnixFileMode.UserRead | UnixFileMode.OtherRead),
            Metadata("/run/credentials-elsewhere/unit/key", 0, UnixFileMode.UserRead | UnixFileMode.GroupRead),
            Metadata("/run/credentials/unit/../key", 0, UnixFileMode.UserRead | UnixFileMode.GroupRead),
            Metadata(systemdPath, 0, UnixFileMode.UserRead | UnixFileMode.GroupRead) with
            {
                HasSymlinkComponent = true
            },
            Metadata(systemdPath, 0, UnixFileMode.UserRead | UnixFileMode.GroupRead) with
            {
                IsReadable = false
            },
            Metadata(systemdPath, 0, UnixFileMode.UserRead | UnixFileMode.GroupRead) with
            {
                IsRegularFile = false
            }
        };
        var target = new NixployTarget
        {
            Secrets = new Dictionary<string, string> { ["app"] = "secrets/prod.env" }
        };

        foreach (var metadata in cases)
        {
            var runner = new RecordingCommandRunner();
            var service = new SopsService(runner, () => metadata.FullPath, _ => metadata);

            await Assert.ThrowsAsync<InvalidOperationException>(() => service.LoadSecretsAsync(target));
            Assert.Empty(runner.Calls);
        }
    }

    [Fact]
    public void Inspect_ReadsActualPrivateRegularFileMetadata()
    {
        if (!OperatingSystem.IsLinux())
        {
            return;
        }

        using var key = PrivateAgeKeyFile();

        var metadata = AgeIdentityFileMetadata.Inspect(key.Name);

        Assert.True(metadata.Exists);
        Assert.True(metadata.IsRegularFile);
        Assert.False(metadata.HasSymlinkComponent);
        Assert.True(metadata.IsReadable);
        Assert.NotEqual(uint.MaxValue, metadata.OwnerUserId);
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, metadata.Mode);
    }

    private static AgeIdentityFileMetadata Metadata(
        string path,
        uint ownerUserId,
        UnixFileMode mode
    ) => new(
        path,
        Exists: true,
        IsRegularFile: true,
        HasSymlinkComponent: false,
        IsReadable: true,
        ownerUserId,
        mode
    );

    private static FileStream PrivateAgeKeyFile()
    {
        var path = Path.Combine(Path.GetTempPath(), $"nixploy-age-{Guid.NewGuid():N}");
        var file = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.ReadWrite | FileShare.Delete,
            4096,
            FileOptions.DeleteOnClose
        );
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        return file;
    }
}
