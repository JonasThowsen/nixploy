using Nixploy.Cli;

ICommandRunner commandRunner = new CommandRunner();
INixployConfigProvider configProvider = new NixployConfigProvider(commandRunner);
IPodmanService podmanService = new PodmanService(commandRunner);
ISopsService sopsService = new SopsService(commandRunner);
IRemoteCommandRunner remoteCommandRunner = new RemoteCommandRunner(commandRunner);
ICaddyService caddyService = new CaddyService(remoteCommandRunner);

return await CommandFactory
    .CreateRootCommand(commandRunner, configProvider, podmanService, sopsService, caddyService)
    .Parse(args)
    .InvokeAsync();
