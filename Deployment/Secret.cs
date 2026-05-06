namespace Nixploy.Cli;

public sealed record Secret(string Name, string Value);

public sealed record SecretMount(string Source, string Target);
