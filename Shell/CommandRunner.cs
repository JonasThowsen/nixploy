using System.Diagnostics;
using System.Text;

namespace Nixploy.Cli;

public class CommandRunner : ICommandRunner
{
    public async Task<CommandRunResult> RunAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        CommandRunOptions? options = null
    )
    {
        options ??= new CommandRunOptions();
        Validate(options);

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = fileName,
                RedirectStandardInput = options.StandardInput is not null,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };

        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        process.Start();

        if (options.StandardInput is not null)
        {
            await process.StandardInput.WriteAsync(options.StandardInput.AsMemory(), options.CancellationToken);
            await process.StandardInput.FlushAsync(options.CancellationToken);
            process.StandardInput.Close();
        }

        var output = new BoundedTextBuffer(options.MaxStandardOutputBytes);
        var error = new BoundedTextBuffer(options.MaxStandardErrorBytes);

        var outputTask = ReadAsync(
            process.StandardOutput,
            output,
            options.StreamOutput ? Console.Out : null
        );

        var errorTask = ReadAsync(
            process.StandardError,
            error,
            options.StreamOutput ? Console.Error : null
        );

        using var timeout = new CancellationTokenSource(options.Timeout);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(
            timeout.Token,
            options.CancellationToken
        );

        var timedOut = false;
        var cancelled = false;

        try
        {
            await process.WaitForExitAsync(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            cancelled = options.CancellationToken.IsCancellationRequested;
            timedOut = !cancelled && timeout.IsCancellationRequested;

            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }

            await process.WaitForExitAsync();
        }

        await Task.WhenAll(outputTask, errorTask);

        var boundedExitCode = cancelled
            ? 130
            : timedOut
                ? 124
                : output.Truncated || error.Truncated
                    ? 125
                    : process.ExitCode;

        return new CommandRunResult(
            boundedExitCode,
            output.Value,
            error.Value,
            output.Truncated,
            error.Truncated,
            timedOut,
            cancelled
        );
    }

    private static void Validate(CommandRunOptions options)
    {
        if (options.Timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(options), "Command timeout must be positive.");
        }

        if (options.MaxStandardOutputBytes <= 0 || options.MaxStandardErrorBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(options), "Command output bounds must be positive.");
        }
    }

    private static async Task ReadAsync(
        TextReader reader,
        BoundedTextBuffer output,
        TextWriter? writer
    )
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            output.AppendLine(line);

            if (writer is not null)
            {
                await writer.WriteLineAsync(line);
            }
        }
    }

    private sealed class BoundedTextBuffer(int maximumBytes)
    {
        private readonly byte[] bytes = new byte[maximumBytes];
        private int count;

        public bool Truncated { get; private set; }

        public string Value => Encoding.UTF8.GetString(bytes, 0, count);

        public void AppendLine(string line)
        {
            var incoming = Encoding.UTF8.GetBytes(line + Environment.NewLine);

            if (incoming.Length >= bytes.Length)
            {
                incoming.AsSpan(incoming.Length - bytes.Length).CopyTo(bytes);
                count = bytes.Length;
                Truncated = true;
                return;
            }

            var overflow = count + incoming.Length - bytes.Length;
            if (overflow > 0)
            {
                bytes.AsSpan(overflow, count - overflow).CopyTo(bytes);
                count -= overflow;
                Truncated = true;
            }

            incoming.CopyTo(bytes, count);
            count += incoming.Length;
        }
    }
}
