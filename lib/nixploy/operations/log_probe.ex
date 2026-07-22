defmodule Nixploy.Operations.LogProbe do
  @moduledoc "Fetches a bounded log snapshot from the currently observed active container."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @tail_lines 200
  @max_output_bytes 65_536
  @command_timeout :timer.seconds(30)
  @safe_name ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/

  def fetch(observed) do
    with :ok <- validate_name(observed.target_identity, :target_identity),
         :ok <- validate_name(observed.active_container, :container_name),
         {:ok, result} <- run_logs(observed) do
      content = normalize_content(result.output_tail, result.output_truncated?)

      {:ok,
       %{
         target_identity: observed.target_identity,
         slot: observed.active_slot,
         container_name: observed.active_container,
         content: content,
         line_count: line_count(content),
         truncated: result.output_truncated?
       }}
    end
  end

  defp run_logs(observed) do
    # TODO(tracer): Establish worker-local Podman connections from explicit
    # target credentials instead of relying on the compatibility deploy adapter.
    executable = Application.get_env(:nixploy, :podman_executable, "podman")

    # TODO(tracer): Add follow mode, explicit slot selection, previous-container
    # lookup, search, retention, and secret-aware redaction after snapshots prove
    # the worker-to-artifact-to-LiveView path.
    command = %Command{
      executable: executable,
      args: [
        "--connection",
        observed.target_identity,
        "logs",
        "--tail",
        Integer.to_string(@tail_lines),
        observed.active_container
      ],
      timeout: @command_timeout,
      max_output_bytes: @max_output_bytes
    }

    case Execution.run(command) do
      {:ok, %{exit_status: 0} = result} ->
        {:ok, result}

      {:ok, result} ->
        {:error, {:podman_logs_failed, result.exit_status, String.trim(result.output_tail)}}

      {:error, reason} ->
        {:error, {:podman_logs_failed, reason}}
    end
  end

  defp validate_name(value, field) when is_binary(value) do
    if Regex.match?(@safe_name, value),
      do: :ok,
      else: {:error, {:unsafe_runtime_name, field, value}}
  end

  defp validate_name(value, field), do: {:error, {:unsafe_runtime_name, field, value}}

  defp normalize_content(output, false), do: String.trim_trailing(output)

  defp normalize_content(output, true) do
    output
    |> drop_partial_first_line()
    |> String.trim_trailing()
  end

  defp drop_partial_first_line(output) do
    case :binary.split(output, "\n") do
      [_partial] -> ""
      [_partial, complete] -> complete
    end
  end

  defp line_count(""), do: 0
  defp line_count(content), do: content |> String.split("\n") |> length()
end
