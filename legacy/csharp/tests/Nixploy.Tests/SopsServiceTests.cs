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
        Assert.Equal(2, runner.Calls.Count);
        var conversion = runner.Calls[0];
        var conversionOptions = conversion.Options!;
        var derivedIdentityPath = conversionOptions.StandardOutputFile!;
        Assert.Equal("ssh-to-age", conversion.FileName);
        Assert.Equal(["-private-key", "-i", key.Name], conversion.Arguments);
        Assert.False(conversionOptions.StreamOutput);
        Assert.False(conversionOptions.RetainStandardError);
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(
                UnixFileMode.UserRead | UnixFileMode.UserWrite,
                runner.OutputFileModeAtCall
            );
            Assert.Equal(
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute,
                runner.OutputDirectoryModeAtCall
            );
        }

        var decrypt = runner.Calls[1];
        Assert.Equal("sops", decrypt.FileName);
        Assert.Equal(["--decrypt", "--input-type", "dotenv", "--output-type", "dotenv", "secrets/prod.env"], decrypt.Arguments);
        Assert.Equal(
            derivedIdentityPath,
            decrypt.Options!.EnvironmentVariables["SOPS_AGE_KEY_FILE"]
        );
        Assert.Null(decrypt.Options.EnvironmentVariables["SOPS_AGE_SSH_PRIVATE_KEY_FILE"]);
        Assert.Null(decrypt.Options.EnvironmentVariables["SOPS_AGE_SSH_PRIVATE_KEY_CMD"]);
        Assert.False(File.Exists(derivedIdentityPath));
        Assert.False(Directory.Exists(Path.GetDirectoryName(derivedIdentityPath)!));
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
        Assert.Equal(2, runner.Calls.Count);
        Assert.Equal("ssh-to-age", runner.Calls[0].FileName);
        Assert.Equal("sops", runner.Calls[1].FileName);
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
    public async Task LoadSecretsAsync_DoesNotRetainOrReportIdentityOnConversionFailure()
    {
        const string privateMaterial = "PRIVATE-IDENTITY-MUST-NOT-ESCAPE";
        var runner = new RecordingCommandRunner(new CommandRunResult(23, privateMaterial, privateMaterial));
        using var key = PrivateAgeKeyFile();
        await using (var writer = new StreamWriter(key, leaveOpen: true))
        {
            await writer.WriteAsync(privateMaterial.AsMemory(), TestContext.Current.CancellationToken);
            await writer.FlushAsync(TestContext.Current.CancellationToken);
        }
        key.Position = 0;
        var service = new SopsService(runner, () => key.Name);
        var target = TargetWithSecrets();

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => service.LoadSecretsAsync(target)
        );

        Assert.DoesNotContain(privateMaterial, exception.Message);
        Assert.Single(runner.Calls);
        var conversionOptions = runner.Calls[0].Options!;
        var derivedIdentityPath = conversionOptions.StandardOutputFile!;
        Assert.False(conversionOptions.RetainStandardError);
        Assert.False(File.Exists(derivedIdentityPath));
        Assert.False(Directory.Exists(Path.GetDirectoryName(derivedIdentityPath)!));
    }

    [Fact]
    public async Task LoadSecretsAsync_CleansDerivedIdentityAfterDecryptFailure()
    {
        var runner = new RecordingCommandRunner(
            new CommandRunResult(0, "", ""),
            new CommandRunResult(9, "", "safe diagnostic")
        );
        using var key = PrivateAgeKeyFile();
        var service = new SopsService(runner, () => key.Name);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => service.LoadSecretsAsync(TargetWithSecrets())
        );

        var derivedPath = runner.Calls[0].Options!.StandardOutputFile!;
        Assert.False(File.Exists(derivedPath));
        Assert.False(Directory.Exists(Path.GetDirectoryName(derivedPath)!));
    }

    [Fact]
    public async Task LoadSecretsAsync_CleansDerivedIdentityAfterCancellation()
    {
        using var key = PrivateAgeKeyFile();
        var runner = new CancellingCommandRunner();
        var service = new SopsService(runner, () => key.Name);

        await Assert.ThrowsAsync<OperationCanceledException>(
            () => service.LoadSecretsAsync(TargetWithSecrets())
        );

        Assert.Equal(2, runner.InvocationCount);
        Assert.NotNull(runner.OutputFile);
        Assert.False(File.Exists(runner.OutputFile));
        Assert.False(Directory.Exists(Path.GetDirectoryName(runner.OutputFile!)!));
    }

    [Fact]
    public async Task LoadSecretsAsync_DoesNotWritePlaintextSecretsToConsoleOrCommandInputs()
    {
        const string value = "plaintext-must-remain-in-memory-only";
        var runner = new RecordingCommandRunner(
            new CommandRunResult(0, "", ""),
            new CommandRunResult(0, $"TOKEN={value}", "")
        );
        using var key = PrivateAgeKeyFile();
        var service = new SopsService(runner, () => key.Name);
        var originalOutput = Console.Out;
        var output = new StringWriter();

        try
        {
            Console.SetOut(output);
            var secrets = await service.LoadSecretsAsync(TargetWithSecrets());
            Assert.Equal(value, Assert.Single(secrets).Value);
        }
        finally
        {
            Console.SetOut(originalOutput);
        }

        Assert.DoesNotContain(value, output.ToString());
        Assert.All(runner.Calls, call =>
        {
            Assert.DoesNotContain(call.Arguments, argument => argument.Contains(value, StringComparison.Ordinal));
            Assert.DoesNotContain(
                call.Options?.EnvironmentVariables.Values ?? [],
                environmentValue => environmentValue?.Contains(value, StringComparison.Ordinal) == true
            );
        });
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

    private static NixployTarget TargetWithSecrets() => new()
    {
        Secrets = new Dictionary<string, string> { ["app"] = "secrets/prod.env" }
    };

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

    private sealed class CancellingCommandRunner : ICommandRunner
    {
        public string? OutputFile { get; private set; }

        public int InvocationCount { get; private set; }

        public Task<CommandRunResult> RunAsync(
            string fileName,
            IReadOnlyList<string> arguments,
            CommandRunOptions? options = null
        )
        {
            InvocationCount++;

            if (options?.StandardOutputFile is { } outputFile)
            {
                OutputFile = outputFile;
                File.WriteAllText(outputFile, "AGE-SECRET-KEY-1TEST\n");
                return Task.FromResult(new CommandRunResult(0, "", ""));
            }

            throw new OperationCanceledException("simulated cancellation");
        }
    }

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
