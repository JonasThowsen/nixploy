using System.Text;
using System.Text.Json;

namespace Nixploy.Cli;

public sealed class DeploymentReporter : IDisposable
{
    public const string Schema = "nixploy.event/v1";
    public const int MaxLineBytes = 65_536;
    public const int MaxProtocolBytes = 1_048_576;
    private const int ReservedTerminalBytes = 4_096;

    private readonly TextWriter? protocol;
    private readonly TextWriter? previousOutput;
    private readonly string operationId;
    private int sequence;
    private int protocolBytes;
    private bool terminal;

    private DeploymentReporter(TextWriter? protocol, TextWriter? previousOutput, string operationId)
    {
        this.protocol = protocol;
        this.previousOutput = previousOutput;
        this.operationId = operationId;
    }

    public bool Enabled => protocol is not null;

    public static DeploymentReporter CreateForProtocol(TextWriter output, string operationId)
    {
        return new DeploymentReporter(output, null, operationId);
    }

    public static DeploymentReporter Create(string? mode, string operationId)
    {
        if (string.IsNullOrWhiteSpace(mode))
        {
            return new DeploymentReporter(null, null, operationId);
        }

        if (!string.Equals(mode, "jsonl", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("--events must be 'jsonl' when supplied.");
        }

        var output = Console.Out;
        Console.SetOut(Console.Error);
        return new DeploymentReporter(output, output, operationId);
    }

    public void Stage(string stage, string message, IReadOnlyDictionary<string, object?>? artifacts = null)
    {
        Emit("stage", stage, null, message, null, artifacts);
    }

    public void Succeed(string message, IReadOnlyDictionary<string, object?>? artifacts = null)
    {
        if (terminal)
        {
            throw new InvalidOperationException("A terminal deployment event was already emitted.");
        }

        terminal = true;
        Emit("terminal", "succeeded", "ok", message, "succeeded", artifacts);
    }

    public void Fail(string code, string message)
    {
        if (terminal)
        {
            return;
        }

        terminal = true;
        Emit("terminal", "failed", code, message, "failed", null);
    }

    public void Dispose()
    {
        if (Enabled && !terminal)
        {
            Fail("remote_cli_failed", "The packaged remote CLI did not complete successfully.");
        }

        if (previousOutput is not null)
        {
            Console.SetOut(previousOutput);
        }
    }

    private void Emit(
        string type,
        string stage,
        string? code,
        string message,
        string? status,
        IReadOnlyDictionary<string, object?>? artifacts
    )
    {
        if (protocol is null)
        {
            return;
        }

        var payload = new Dictionary<string, object?>
        {
            ["schema"] = Schema,
            ["seq"] = ++sequence,
            ["type"] = type,
            ["stage"] = stage,
            ["code"] = code,
            ["message"] = message,
            ["operation_id"] = operationId,
            ["status"] = status,
            ["artifacts"] = artifacts ?? new Dictionary<string, object?>()
        };

        var line = JsonSerializer.Serialize(payload);
        var bytes = Encoding.UTF8.GetByteCount(line) + 1;

        var totalLimit = type == "terminal"
            ? MaxProtocolBytes
            : MaxProtocolBytes - ReservedTerminalBytes;

        if (bytes > MaxLineBytes || protocolBytes + bytes > totalLimit)
        {
            throw new InvalidOperationException("Deployment event protocol output exceeded its byte bound.");
        }

        protocol.WriteLine(line);
        protocol.Flush();
        protocolBytes += bytes;
    }
}
