defmodule Nixploy.Tasks.RemoteExecutor do
  @moduledoc false

  alias Nixploy.Deployments.{DeploymentPolicy, EventProtocol}
  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @max_output 1_114_112

  def run(operation, deployment, task, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    policy = Keyword.get(opts, :policy, DeploymentPolicy)
    workspace = Path.join(workspace_root(opts), operation.id)

    try do
      with {:ok, decision} <- policy.evaluate(deployment, operation: :task),
           true <- decision.allow? or {:error, :task_policy_denied},
           :ok <- File.mkdir_p(workspace),
           :ok <- File.chmod(workspace, 0o700) do
        state_key = {__MODULE__, make_ref()}

        Process.put(state_key, %{
          protocol: EventProtocol.initial(),
          error: nil,
          outcome: nil,
          output: "",
          truncated?: false
        })

        on_line = fn line -> consume(line, operation.id, state_key) end

        execution_opts =
          [on_line: on_line]
          |> Keyword.merge(Keyword.take(opts, [:cancelled?]))

        result = execute.(command(operation, deployment, task, workspace, opts), execution_opts)
        state = Process.delete(state_key)
        finish(result, state)
      else
        false -> {:error, :task_policy_denied}
        {:error, _reason} = error -> error
      end
    after
      File.rm_rf(workspace)
    end
  end

  def command(operation, deployment, task, workspace, opts \\ []) do
    input = deployment.deployment_input

    executable =
      Keyword.get_lazy(
        opts,
        :executable,
        fn -> Application.fetch_env!(:nixploy, :remote_cli_executable) end
      )

    %Command{
      executable: executable,
      args: [
        "task",
        "--target",
        deployment.target,
        "--task",
        operation.task_name,
        "--source",
        input.store_path,
        "--git-revision",
        input.source_revision,
        "--repository-identity",
        input.source_repository,
        "--configuration-digest",
        input.configuration_digest,
        "--operation-id",
        operation.id,
        "--resource-key",
        operation.resource_key,
        "--image-reference",
        deployment.image_reference,
        "--image-id",
        deployment.image_id,
        "--events",
        "jsonl"
      ],
      cd: workspace,
      env: %{
        "HOME" => workspace,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null"
      },
      timeout: task["timeout_seconds"] * 1_000 + 30_000,
      max_output_bytes: @max_output
    }
  end

  defp consume(line, operation_id, key) do
    state = Process.get(key)

    case EventProtocol.consume(line, state.protocol, operation_id) do
      {:diagnostic, diagnostic, protocol} ->
        {output, truncated?} = bounded_tail(state.output <> diagnostic <> "\n", 65_536)

        Process.put(key, %{
          state
          | protocol: protocol,
            output: output,
            truncated?: state.truncated? or truncated?
        })

      {:event, %{type: :terminal, stage: stage}, protocol} ->
        Process.put(key, %{state | protocol: protocol, outcome: stage})

      {:event, _event, protocol} ->
        Process.put(key, %{state | protocol: protocol})

      {:error, reason} ->
        Process.put(key, %{state | error: reason})
    end
  end

  defp finish({:error, reason}, state), do: {:error, reason, evidence(state)}

  defp finish({:ok, %{output_truncated?: true}}, state),
    do: {:error, :task_output_too_large, evidence(state)}

  defp finish(_result, %{error: reason} = state) when not is_nil(reason),
    do: {:error, reason, evidence(state)}

  defp finish({:ok, %{exit_status: 0}}, %{outcome: :succeeded} = state),
    do: {:ok, evidence(state)}

  defp finish({:ok, %{exit_status: status}}, state),
    do: {:error, {:task_cli_failed, status, state.outcome}, evidence(state)}

  defp evidence(state), do: %{output_tail: state.output, output_truncated: state.truncated?}

  defp bounded_tail(output, limit) when byte_size(output) <= limit, do: {output, false}

  defp bounded_tail(output, limit),
    do: {binary_part(output, byte_size(output) - limit, limit), true}

  defp workspace_root(opts),
    do:
      Keyword.get(
        opts,
        :workspace_root,
        Application.get_env(:nixploy, :operation_workspace_root, "/var/lib/nixploy/operations")
      )
end
