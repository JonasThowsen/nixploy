using System.Text.Json.Serialization;

namespace Nixploy.Cli;

public sealed record NixployConfig
{
    [JsonPropertyName("__schema")]
    public string Schema { get; init; } = "";

    [JsonPropertyName("project")]
    public string Project { get; init; } = "";

    [JsonPropertyName("targets")]
    public Dictionary<string, NixployTarget> Targets { get; init; } = [];
}

public sealed record NixployTarget
{
    [JsonPropertyName("image")]
    public string Image { get; init; } = "";

    [JsonPropertyName("ip")]
    public string Ip { get; init; } = "";

    [JsonPropertyName("user")]
    public string User { get; init; } = "root";

    [JsonPropertyName("port")]
    public int Port { get; init; } = 22;

    [JsonPropertyName("identityFile")]
    public string? IdentityFile { get; init; }

    [JsonPropertyName("run")]
    public NixployRunConfig Run { get; init; } = new();

    [JsonPropertyName("web")]
    public NixployWebConfig? Web { get; init; }

    [JsonPropertyName("secrets")]
    public Dictionary<string, string> Secrets { get; init; } = [];
}

public sealed record NixployRunConfig
{
    [JsonPropertyName("command")]
    public IReadOnlyList<string>? Command { get; init; }

    [JsonPropertyName("environment")]
    public Dictionary<string, string> Environment { get; init; } = [];

    [JsonPropertyName("preStart")]
    public IReadOnlyList<IReadOnlyList<string>> PreStart { get; init; } = [];

    [JsonPropertyName("network")]
    public string? Network { get; init; }

    [JsonPropertyName("ports")]
    public IReadOnlyList<string> Ports { get; init; } = [];

    [JsonPropertyName("readOnlyBinds")]
    public IReadOnlyList<NixployReadOnlyBind> ReadOnlyBinds { get; init; } = [];
}

public sealed record NixployReadOnlyBind
{
    [JsonPropertyName("source")]
    public string Source { get; init; } = "";

    [JsonPropertyName("destination")]
    public string Destination { get; init; } = "";
}

public sealed record NixployWebConfig
{
    [JsonPropertyName("domain")]
    public string Domain { get; init; } = "";

    [JsonPropertyName("healthPath")]
    public string HealthPath { get; init; } = "/health";

    [JsonPropertyName("slots")]
    public NixployWebSlots Slots { get; init; } = new();
}

public sealed record NixployWebSlots
{
    [JsonPropertyName("blue")]
    public int Blue { get; init; } = 8080;

    [JsonPropertyName("green")]
    public int Green { get; init; } = 8081;
}
