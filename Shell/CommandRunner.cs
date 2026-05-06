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

        if (options.Interactive && options.StandardInput is not null)
        {
            throw new InvalidOperationException("Interactive commands cannot also provide StandardInput.");
        }

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = fileName,
                RedirectStandardInput = !options.Interactive && options.StandardInput is not null,
                RedirectStandardOutput = !options.Interactive,
                RedirectStandardError = !options.Interactive,
                UseShellExecute = false,
                CreateNoWindow = !options.Interactive
            }
        };

        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        process.Start();

        if (options.Interactive)
        {
            await process.WaitForExitAsync();
            return new CommandRunResult(process.ExitCode, "", "");
        }

        if (options.StandardInput is not null)
        {
            await process.StandardInput.WriteAsync(options.StandardInput);
            await process.StandardInput.FlushAsync();
            process.StandardInput.Close();
        }

        var output = new StringBuilder();
        var error = new StringBuilder();

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

        await process.WaitForExitAsync();
        await Task.WhenAll(outputTask, errorTask);

        return new CommandRunResult(
            process.ExitCode,
            output.ToString(),
            error.ToString()
        );
    }

    private static async Task ReadAsync(
        TextReader reader,
        StringBuilder output,
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
}
