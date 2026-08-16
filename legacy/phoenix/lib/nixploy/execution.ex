defmodule Nixploy.Execution do
  @moduledoc "Runs typed external commands with streamed lines and cooperative cancellation."

  alias Nixploy.Execution.Command

  defmodule Result do
    @moduledoc false
    defstruct [:exit_status, :output_tail, output_truncated?: false]

    @type t :: %__MODULE__{
            exit_status: non_neg_integer(),
            output_tail: String.t(),
            output_truncated?: boolean()
          }
  end

  @poll_interval 250
  @termination_grace :timer.seconds(7)
  @line_bytes 4_096

  @spec run(Command.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Command{} = command, opts \\ []) do
    with {:ok, executable} <- find_executable(command.executable),
         {:ok, {port_executable, args, termination_mode}} <-
           process(executable, command.args, command.stdin) do
      port = open_port(port_executable, args, command)
      :ok = write_stdin(port, command.stdin)
      os_pid = port_os_pid(port)
      started_at = System.monotonic_time(:millisecond)

      receive_output(
        port,
        command,
        opts,
        started_at,
        os_pid,
        termination_mode,
        "",
        "",
        false,
        nil,
        false,
        nil,
        nil
      )
    end
  rescue
    error -> {:error, {:spawn_failed, Exception.message(error)}}
  end

  defp find_executable(executable) do
    case System.find_executable(executable) do
      nil -> {:error, {:executable_not_found, executable}}
      path -> {:ok, path}
    end
  end

  defp process(executable, args, stdin) do
    wrapper = Path.join(:code.priv_dir(:nixploy), "execution_wrapper.sh")

    with bash when is_binary(bash) <- System.find_executable("bash"),
         setsid when is_binary(setsid) <- System.find_executable("setsid"),
         head when is_binary(head) <- System.find_executable("head"),
         true <- File.regular?(wrapper) do
      stdin_bytes = if is_binary(stdin), do: Integer.to_string(byte_size(stdin)), else: "-"
      {:ok, {bash, [wrapper, setsid, head, stdin_bytes, executable | args], :wrapper}}
    else
      _unavailable -> {:error, :process_group_support_unavailable}
    end
  end

  defp write_stdin(_port, nil), do: :ok

  defp write_stdin(port, stdin) when is_binary(stdin) do
    if Port.command(port, stdin), do: :ok, else: raise("could not write command stdin")
  end

  defp open_port(executable, args, command) do
    options = [
      :binary,
      :eof,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:args, args}
    ]

    options =
      if command.cd,
        do: [{:cd, String.to_charlist(command.cd)} | options],
        else: options

    options =
      if map_size(command.env) > 0 do
        environment =
          Enum.map(command.env, fn
            {key, false} -> {String.to_charlist(key), false}
            {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
          end)

        [{:env, environment} | options]
      else
        options
      end

    Port.open({:spawn_executable, executable}, options)
  end

  defp receive_output(
         port,
         command,
         opts,
         started_at,
         os_pid,
         termination_mode,
         line_buffer,
         output_tail,
         output_truncated?,
         exit_status,
         eof?,
         termination_reason,
         termination_started_at
       ) do
    receive do
      {^port, {:data, data}} ->
        {line_buffer, output_tail, output_truncated?} =
          consume(data, line_buffer, output_tail, output_truncated?, command, opts)

        continue(
          port,
          command,
          opts,
          started_at,
          os_pid,
          termination_mode,
          line_buffer,
          output_tail,
          output_truncated?,
          exit_status,
          eof?,
          termination_reason,
          termination_started_at
        )

      {^port, {:exit_status, status}} ->
        if eof? do
          finish(
            status,
            line_buffer,
            output_tail,
            output_truncated?,
            command,
            opts,
            termination_reason
          )
        else
          receive_output(
            port,
            command,
            opts,
            started_at,
            os_pid,
            termination_mode,
            line_buffer,
            output_tail,
            output_truncated?,
            status,
            false,
            termination_reason,
            termination_started_at
          )
        end

      {^port, :eof} ->
        if is_integer(exit_status) do
          finish(
            exit_status,
            line_buffer,
            output_tail,
            output_truncated?,
            command,
            opts,
            termination_reason
          )
        else
          receive_output(
            port,
            command,
            opts,
            started_at,
            os_pid,
            termination_mode,
            line_buffer,
            output_tail,
            output_truncated?,
            nil,
            true,
            termination_reason,
            termination_started_at
          )
        end
    after
      @poll_interval ->
        continue(
          port,
          command,
          opts,
          started_at,
          os_pid,
          termination_mode,
          line_buffer,
          output_tail,
          output_truncated?,
          exit_status,
          eof?,
          termination_reason,
          termination_started_at
        )
    end
  end

  defp continue(
         port,
         command,
         opts,
         started_at,
         os_pid,
         termination_mode,
         line_buffer,
         output_tail,
         output_truncated?,
         exit_status,
         eof?,
         termination_reason,
         termination_started_at
       ) do
    cond do
      termination_reason &&
          System.monotonic_time(:millisecond) - termination_started_at >= @termination_grace ->
        signal_process(os_pid, "KILL")
        close_port(port)
        {:error, termination_reason}

      termination_reason ->
        receive_output(
          port,
          command,
          opts,
          started_at,
          os_pid,
          termination_mode,
          line_buffer,
          output_tail,
          output_truncated?,
          exit_status,
          eof?,
          termination_reason,
          termination_started_at
        )

      cancelled?(opts) ->
        begin_termination(
          port,
          command,
          opts,
          started_at,
          os_pid,
          termination_mode,
          line_buffer,
          output_tail,
          output_truncated?,
          exit_status,
          eof?,
          :cancelled
        )

      timed_out?(command.timeout, started_at) ->
        begin_termination(
          port,
          command,
          opts,
          started_at,
          os_pid,
          termination_mode,
          line_buffer,
          output_tail,
          output_truncated?,
          exit_status,
          eof?,
          :timeout
        )

      true ->
        receive_output(
          port,
          command,
          opts,
          started_at,
          os_pid,
          termination_mode,
          line_buffer,
          output_tail,
          output_truncated?,
          exit_status,
          eof?,
          nil,
          nil
        )
    end
  end

  defp begin_termination(
         port,
         command,
         opts,
         started_at,
         os_pid,
         termination_mode,
         line_buffer,
         output_tail,
         output_truncated?,
         exit_status,
         eof?,
         reason
       ) do
    signal_termination(port, os_pid, termination_mode)

    receive_output(
      port,
      command,
      opts,
      started_at,
      os_pid,
      termination_mode,
      line_buffer,
      output_tail,
      output_truncated?,
      exit_status,
      eof?,
      reason,
      System.monotonic_time(:millisecond)
    )
  end

  defp finish(
         _exit_status,
         line_buffer,
         _output_tail,
         _output_truncated?,
         command,
         opts,
         termination_reason
       )
       when not is_nil(termination_reason) do
    emit_line(line_buffer, command, opts)
    {:error, termination_reason}
  end

  defp finish(
         exit_status,
         line_buffer,
         output_tail,
         output_truncated?,
         command,
         opts,
         nil
       ) do
    emit_line(line_buffer, command, opts)
    output_tail = output_tail |> valid_text() |> redact(command.redact)

    {:ok,
     %Result{
       exit_status: exit_status,
       output_tail: output_tail,
       output_truncated?: output_truncated?
     }}
  end

  defp consume(data, line_buffer, output_tail, output_truncated?, command, opts) do
    {output_tail, truncated_now?} =
      bounded_tail(output_tail <> data, command.max_output_bytes)

    parts = :binary.split(line_buffer <> data, "\n", [:global])
    {complete_lines, [next_buffer]} = Enum.split(parts, -1)
    Enum.each(complete_lines, &emit_line(&1, command, opts))
    next_buffer = emit_complete_chunks(next_buffer, command, opts)
    {next_buffer, output_tail, output_truncated? or truncated_now?}
  end

  defp emit_complete_chunks(buffer, command, opts) when byte_size(buffer) > @line_bytes do
    <<chunk::binary-size(@line_bytes), rest::binary>> = buffer
    emit_line(chunk, command, opts)
    emit_complete_chunks(rest, command, opts)
  end

  defp emit_complete_chunks(buffer, _command, _opts), do: buffer

  defp emit_line("", _command, _opts), do: :ok

  defp emit_line(line, command, opts) do
    line =
      line
      |> valid_text()
      |> String.trim_trailing("\r")
      |> redact(command.redact)
      |> truncate_line()

    case Keyword.get(opts, :on_line) do
      callback when is_function(callback, 1) -> callback.(line)
      _callback -> :ok
    end
  end

  defp redact(line, values) do
    Enum.reduce(values, line, fn
      value, redacted when is_binary(value) and value != "" ->
        String.replace(redacted, value, "[REDACTED]")

      _value, redacted ->
        redacted
    end)
  end

  defp truncate_line(line) when byte_size(line) <= @line_bytes, do: line

  defp truncate_line(line) do
    line
    |> binary_part(0, @line_bytes)
    |> valid_text()
    |> Kernel.<>("…")
  end

  defp bounded_tail(output, limit) when byte_size(output) <= limit, do: {output, false}

  defp bounded_tail(output, limit) do
    {binary_part(output, byte_size(output) - limit, limit), true}
  end

  defp valid_text(value), do: String.replace_invalid(value, "�")

  defp cancelled?(opts) do
    case Keyword.get(opts, :cancelled?) do
      callback when is_function(callback, 0) -> callback.()
      _callback -> false
    end
  end

  defp timed_out?(:infinity, _started_at), do: false

  defp timed_out?(timeout, started_at) do
    System.monotonic_time(:millisecond) - started_at >= timeout
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp signal_termination(_port, os_pid, :wrapper) when is_integer(os_pid) do
    signal_process(os_pid, "TERM")
  end

  defp signal_termination(port, _os_pid, _termination_mode), do: close_port(port)

  defp signal_process(os_pid, signal) do
    if kill = System.find_executable("kill") do
      _ =
        System.cmd(kill, ["-#{signal}", "--", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
end
