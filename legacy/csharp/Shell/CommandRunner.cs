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

        foreach (var (name, value) in options.EnvironmentVariables)
        {
            if (value is null)
            {
                process.StartInfo.Environment.Remove(name);
            }
            else
            {
                process.StartInfo.Environment[name] = value;
            }
        }

        process.Start();

        if (options.StandardInput is not null)
        {
            await process.StandardInput.WriteAsync(options.StandardInput.AsMemory(), options.CancellationToken);
            await process.StandardInput.FlushAsync(options.CancellationToken);
            process.StandardInput.Close();
        }

        var output = options.StandardOutputFile is null
            ? new BoundedTextBuffer(options.MaxStandardOutputBytes)
            : null;
        var error = options.RetainStandardError
            ? new BoundedTextBuffer(options.MaxStandardErrorBytes)
            : null;

        using var outputFile = options.StandardOutputFile is null
            ? null
            : new FileStream(
                options.StandardOutputFile,
                FileMode.Truncate,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.Asynchronous | FileOptions.SequentialScan
            );

        var outputTask = outputFile is null
            ? ReadAsync(
                process.StandardOutput,
                output,
                options.StreamOutput ? Console.Out : null,
                options.MaxStandardOutputBytes
            )
            : CopyBoundedAsync(
                process.StandardOutput.BaseStream,
                outputFile,
                options.MaxStandardOutputBytes
            );

        var errorTask = ReadAsync(
            process.StandardError,
            error,
            options.StreamOutput ? Console.Error : null,
            options.MaxStandardErrorBytes
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

        var outputTruncated = outputTask.Result;
        var errorTruncated = errorTask.Result;
        var boundedExitCode = cancelled
            ? 130
            : timedOut
                ? 124
                : outputTruncated || errorTruncated
                    ? 125
                    : process.ExitCode;

        return new CommandRunResult(
            boundedExitCode,
            output?.Value ?? "",
            error?.Value ?? "",
            outputTruncated,
            errorTruncated,
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

    private static async Task<bool> ReadAsync(
        TextReader reader,
        BoundedTextBuffer? output,
        TextWriter? writer,
        int maximumBytes
    )
    {
        var observedBytes = 0L;

        while (await reader.ReadLineAsync() is { } line)
        {
            observedBytes += Encoding.UTF8.GetByteCount(line + Environment.NewLine);
            output?.AppendLine(line);

            if (writer is not null)
            {
                await writer.WriteLineAsync(line);
            }
        }

        return output?.Truncated ?? observedBytes > maximumBytes;
    }

    private static async Task<bool> CopyBoundedAsync(
        Stream source,
        Stream destination,
        int maximumBytes
    )
    {
        var buffer = new byte[8192];
        var written = 0;
        var truncated = false;
        int count;

        while ((count = await source.ReadAsync(buffer)) > 0)
        {
            var remaining = maximumBytes - written;
            var writeCount = Math.Min(count, Math.Max(remaining, 0));

            if (writeCount > 0)
            {
                await destination.WriteAsync(buffer.AsMemory(0, writeCount));
                written += writeCount;
            }

            truncated |= writeCount != count;
        }

        await destination.FlushAsync();
        return truncated;
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
