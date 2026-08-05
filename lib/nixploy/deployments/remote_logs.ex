defmodule Nixploy.Deployments.RemoteLogs do
  @moduledoc "Reads one bounded redacted log snapshot for an exact managed remote container."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @timeout :timer.seconds(45)
  @max_output 65_536
  @max_content 60_000
  @max_lines 200
  @sensitive ~r/\b(password|passwd|token|secret|api[_-]?key)\s*[:=]\s*/i

  def read(deployment, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    key = {__MODULE__, make_ref()}
    Process.put(key, %{snapshot: nil, error: nil})
    result = execute.(command(deployment, opts), on_line: &consume(&1, deployment, key))
    state = Process.delete(key)

    case {result, state} do
      {_result, %{error: reason}} when not is_nil(reason) ->
        {:error, reason}

      {{:ok, %{exit_status: 0, output_truncated?: false}}, %{snapshot: snapshot}}
      when is_map(snapshot) ->
        {:ok, snapshot}

      {{:ok, %{output_truncated?: true}}, _state} ->
        {:error, :logs_output_too_large}

      {{:ok, %{exit_status: 0}}, _state} ->
        {:error, :logs_observation_missing}

      {{:ok, %{exit_status: status}}, _state} ->
        {:error, {:logs_failed, status}}

      {{:error, reason}, _state} ->
        {:error, reason}

      _other ->
        {:error, :logs_observation_missing}
    end
  end

  def command(deployment, opts \\ []) do
    input = deployment.deployment_input

    executable =
      Keyword.get_lazy(opts, :executable, fn ->
        Application.fetch_env!(:nixploy, :remote_cli_executable)
      end)

    %Command{
      executable: executable,
      args: [
        "logs",
        "--target",
        deployment.target,
        "--source",
        input.store_path,
        "--git-revision",
        input.source_revision,
        "--repository-identity",
        input.source_repository,
        "--configuration-digest",
        input.configuration_digest,
        "--operation-id",
        deployment.id,
        "--resource-key",
        deployment.resource_prefix,
        "--container-name",
        deployment.container_name
      ],
      timeout: @timeout,
      max_output_bytes: @max_output
    }
  end

  defp consume(line, deployment, key) do
    state = Process.get(key)

    case Jason.decode(line) do
      {:ok, %{"schema" => "nixploy.logs/v1"} = snapshot} ->
        case validate(snapshot, deployment) do
          :ok when is_nil(state.snapshot) -> Process.put(key, %{state | snapshot: snapshot})
          :ok -> Process.put(key, %{state | error: :duplicate_logs_observation})
          {:error, reason} -> Process.put(key, %{state | error: reason})
        end

      _diagnostic ->
        :ok
    end
  end

  defp validate(snapshot, deployment) do
    content = snapshot["content"]
    line_count = snapshot["line_count"]

    cond do
      snapshot["operation_id"] != deployment.id ->
        {:error, :logs_operation_mismatch}

      snapshot["resource_key"] != deployment.resource_prefix ->
        {:error, :logs_resource_mismatch}

      snapshot["container_name"] != deployment.container_name ->
        {:error, :logs_container_mismatch}

      not is_binary(content) or byte_size(content) > @max_content ->
        {:error, :logs_content_invalid}

      not is_integer(line_count) or line_count not in 0..@max_lines ->
        {:error, :logs_line_count_invalid}

      line_count != count_lines(content) ->
        {:error, :logs_line_count_invalid}

      not is_boolean(snapshot["truncated"]) ->
        {:error, :logs_shape_invalid}

      sensitive_unredacted?(content) ->
        {:error, :logs_secret_shape_detected}

      not valid_timestamp?(snapshot["observed_at"]) ->
        {:error, :logs_timestamp_invalid}

      true ->
        :ok
    end
  end

  defp count_lines(""), do: 0
  defp count_lines(content), do: content |> String.split("\n") |> length()

  defp sensitive_unredacted?(content) do
    content
    |> String.split("\n")
    |> Enum.any?(fn line ->
      Regex.match?(@sensitive, line) and not String.contains?(line, "[REDACTED]")
    end)
  end

  defp valid_timestamp?(value) when is_binary(value),
    do: match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))

  defp valid_timestamp?(_value), do: false
end
