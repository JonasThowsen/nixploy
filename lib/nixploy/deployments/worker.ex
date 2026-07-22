defmodule Nixploy.Deployments.Worker do
  @moduledoc "Runs the first real deployment tracer through Git and the existing nixploy CLI."

  use Oban.Worker,
    queue: :deployments,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:args], states: :incomplete]

  alias Nixploy.Deployments
  alias Nixploy.Deployments.{Deployment, LegacyExecutor, Source}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"deployment_id" => deployment_id}}) do
    deployment = Deployments.get_deployment!(deployment_id)

    cond do
      Deployment.terminal?(deployment) ->
        :ok

      deployment.cancellation_requested_at ->
        cancel(deployment)

      true ->
        run(deployment)
    end
  end

  defp run(deployment) do
    try do
      do_run(deployment)
    after
      _ = Source.cleanup(deployment.id)
    end
  end

  defp do_run(deployment) do
    with {:ok, deployment} <- prepare(deployment),
         {:ok, workspace, commit} <- checkout(deployment),
         {:ok, deployment} <- record_commit(deployment, commit),
         {:ok, _result} <- execute(deployment, workspace),
         {:ok, _deployment} <- complete(deployment.id) do
      :ok
    else
      {:cancelled, deployment} -> cancel(deployment)
      {:error, reason} -> fail(deployment.id, reason)
    end
  end

  defp prepare(%{state: :queued} = deployment) do
    case Deployments.transition(deployment.id, :preparing, "Preparing source checkout") do
      {:ok, _deployment, _event} -> {:ok, Deployments.get_deployment!(deployment.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare(deployment), do: {:ok, deployment}

  defp checkout(deployment) do
    opts = command_options(deployment.id, "source")

    case Source.prepare(deployment, opts) do
      {:ok, workspace, commit} -> {:ok, workspace, commit}
      {:error, :cancelled} -> {:cancelled, Deployments.get_deployment!(deployment.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_commit(%{state: :preparing} = deployment, commit) do
    message = "Resolved #{deployment.requested_ref} to #{short_commit(commit)}"

    case Deployments.transition(deployment.id, :building, message, %{resolved_commit: commit}) do
      {:ok, _deployment, _event} -> {:ok, Deployments.get_deployment!(deployment.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_commit(deployment, _commit), do: {:ok, deployment}

  defp execute(deployment, workspace) do
    _ =
      Deployments.record_event(
        deployment.id,
        "execution",
        :info,
        "Delegating deployment to the existing nixploy CLI"
      )

    case LegacyExecutor.deploy(deployment, workspace, command_options(deployment.id, "execution")) do
      {:error, :cancelled} ->
        {:cancelled, Deployments.get_deployment!(deployment.id)}

      result ->
        result
    end
  end

  # TODO(tracer): Transition stages at their real execution boundaries as the
  # compatibility CLI is replaced; it currently returns only a final result.
  defp complete(deployment_id) do
    with {:ok, deployment} <-
           transition_if_needed(
             deployment_id,
             :deploying,
             "Image built and deployment command completed"
           ),
         {:ok, deployment} <-
           transition_if_needed(deployment.id, :verifying, "Finalizing deployment result"),
         {:ok, deployment} <-
           transition_if_needed(deployment.id, :succeeded, "Deployment succeeded") do
      {:ok, deployment}
    end
  end

  defp transition_if_needed(deployment_id, next_state, message) do
    deployment = Deployments.get_deployment!(deployment_id)
    states = Deployment.states()
    current_index = Enum.find_index(states, &(&1 == deployment.state))
    next_index = Enum.find_index(states, &(&1 == next_state))

    cond do
      Deployment.terminal?(deployment) ->
        {:error, {:terminal, deployment.state}}

      current_index >= next_index ->
        {:ok, deployment}

      true ->
        case Deployments.transition(deployment.id, next_state, message) do
          {:ok, deployment, _event} -> {:ok, deployment}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # TODO(tracer): Move full command output into bounded artifact chunks and
  # retain only structured progress events in PostgreSQL before logs grow large.
  defp command_options(deployment_id, stage) do
    [
      cancelled?: fn -> Deployments.cancellation_requested?(deployment_id) end,
      on_line: fn line ->
        _ = Deployments.record_event(deployment_id, stage, :info, line)
        :ok
      end
    ]
  end

  defp cancel(deployment) do
    case Deployments.transition(deployment.id, :cancelled, "Deployment cancelled") do
      {:ok, _deployment, _event} ->
        :ok

      {:error, {:invalid_transition, state, :cancelled}}
      when state in [:succeeded, :failed, :cancelled] ->
        :ok

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp fail(deployment_id, reason) do
    deployment = Deployments.get_deployment!(deployment_id)

    if Deployment.terminal?(deployment) do
      :ok
    else
      message = failure_message(reason)

      case Deployments.transition(deployment.id, :failed, "Deployment failed: #{message}", %{
             failure: %{message: message}
           }) do
        {:ok, _deployment, _event} -> :ok
        {:error, transition_reason} -> {:error, inspect(transition_reason)}
      end
    end
  end

  defp failure_message({:executable_not_found, executable}),
    do: "executable not found: #{executable}"

  defp failure_message({:git_failed, status, output}),
    do: "Git exited with status #{status}: #{tail(output)}"

  defp failure_message({:legacy_cli_failed, status, output}),
    do: "nixploy exited with status #{status}: #{tail(output)}"

  defp failure_message({:missing_success_marker, output}),
    do: "nixploy did not report successful completion: #{tail(output)}"

  defp failure_message({:invalid_repository_subdirectory, subdirectory}),
    do: "invalid repository subdirectory: #{subdirectory}"

  defp failure_message({:repository_subdirectory_not_found, subdirectory}),
    do: "repository subdirectory not found: #{subdirectory}"

  defp failure_message(:process_group_support_unavailable),
    do: "safe command execution requires bash and setsid"

  defp failure_message(:timeout), do: "command timed out"
  defp failure_message(reason), do: inspect(reason)

  defp tail(output) do
    output
    |> String.trim()
    |> String.slice(-1_000, 1_000)
  end

  defp short_commit(commit), do: String.slice(commit, 0, 12)
end
