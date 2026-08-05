using Nixploy.Cli;
using Xunit;

namespace Nixploy.Tests;

public sealed class DeploymentCompensationTests
{
    [Fact]
    public async Task FailedIngressReadbackRestoresPriorRouteAndRemovesCandidate()
    {
        var commands = new RecordingCommandRunner(new CommandRunResult(0, "", ""));
        var podman = new FixturePodmanService();
        var caddy = new FixtureCaddyService(8080, 9999, 8080);
        var root = CommandFactory.CreateRootCommand(
            commands,
            new FixtureConfigProvider(),
            podman,
            new EmptySopsService(),
            caddy
        );

        var status = await root.Parse([
            "deploy",
            "--target", "production",
            "--source", "/nix/store/aaaaaaaa-source",
            "--git-revision", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "--repository-identity", "fixture/repository",
            "--configuration-digest", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "--operation-id", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "--resource-key", "nixploy-fixture-bab0990cab-production"
        ]).InvokeAsync();

        Assert.Equal(1, status);
        Assert.Equal([8081, 8080], caddy.SwitchPorts);
        Assert.Contains("nixploy-fixture-bab0990cab-production-green", podman.StoppedContainers);
        Assert.DoesNotContain("nixploy-fixture-bab0990cab-production-blue", podman.StoppedContainers);
    }

    private sealed class FixtureConfigProvider : INixployConfigProvider
    {
        public Task<NixployConfig> GetConfigAsync(string source)
        {
            return Task.FromResult(new NixployConfig
            {
                Project = "fixture",
                Targets = new Dictionary<string, NixployTarget>
                {
                    ["production"] = new NixployTarget
                    {
                        Image = "docker",
                        Ip = "203.0.113.10",
                        User = "deploy",
                        Run = new NixployRunConfig { Network = "host" },
                        Web = new NixployWebConfig
                        {
                            Domain = "fixture.example.test",
                            Slots = new NixployWebSlots { Blue = 8080, Green = 8081 }
                        }
                    }
                }
            });
        }
    }

    private sealed class EmptySopsService : ISopsService
    {
        public Task<IReadOnlyList<Secret>> LoadSecretsAsync(NixployTarget target) =>
            Task.FromResult<IReadOnlyList<Secret>>([]);
    }

    private sealed class FixtureCaddyService(params int?[] readbacks) : ICaddyService
    {
        private readonly Queue<int?> readbacks = new(readbacks);
        public List<int> SwitchPorts { get; } = [];

        public Task<ActivePortResult> GetActivePortAsync(string resourcePrefix, NixployTarget target) =>
            Task.FromResult(new ActivePortResult(true, readbacks.Dequeue()));

        public Task<bool> CheckHealthAsync(NixployTarget target, int port) => Task.FromResult(true);

        public Task<bool> SwitchAsync(string resourcePrefix, NixployTarget target, int port)
        {
            SwitchPorts.Add(port);
            return Task.FromResult(true);
        }

        public Task<bool> DeleteRouteAsync(string resourcePrefix, NixployTarget target) =>
            Task.FromResult(true);
    }

    private sealed class FixturePodmanService : IPodmanService
    {
        public List<string> StoppedContainers { get; } = [];

        public string GetConnectionName(string resourcePrefix) => resourcePrefix;

        public Task<bool> EnsureConnectionAsync(string resourcePrefix, string targetName, NixployTarget target) =>
            Task.FromResult(true);

        public Task<LoadedImage?> LoadImageAsync(string connectionName, string imagePath) =>
            Task.FromResult<LoadedImage?>(new LoadedImage("localhost/fixture:latest"));

        public Task<IReadOnlyList<SecretMount>?> InstallSecretsAsync(
            string connectionName,
            string resourcePrefix,
            IReadOnlyList<Secret> secrets
        ) => Task.FromResult<IReadOnlyList<SecretMount>?>([]);

        public Task<bool> RunPreStartCommandsAsync(
            string connectionName,
            string imageReference,
            IReadOnlyList<IReadOnlyList<string>> commands,
            string? network,
            IReadOnlyDictionary<string, string> environment,
            int? port,
            IReadOnlyList<SecretMount> secrets
        ) => Task.FromResult(true);

        public Task<bool> RunImageAsync(
            string connectionName,
            string containerName,
            string imageReference,
            NixployRunConfig runConfig,
            int? port,
            IReadOnlyList<SecretMount> secrets,
            DeploymentMetadata metadata
        ) => Task.FromResult(true);

        public Task<VerifiedContainer?> VerifyContainerAsync(
            string connectionName,
            string containerName,
            string imageReference,
            DeploymentMetadata metadata
        ) => Task.FromResult<VerifiedContainer?>(new VerifiedContainer("id", containerName, imageReference));

        public Task StopContainerAsync(string connectionName, string containerName)
        {
            StoppedContainers.Add(containerName);
            return Task.CompletedTask;
        }

        public Task<bool> PruneTargetAsync(string connectionName, string resourcePrefix) =>
            Task.FromResult(true);
    }
}
