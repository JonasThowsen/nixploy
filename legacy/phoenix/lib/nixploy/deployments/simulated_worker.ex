defmodule Nixploy.Deployments.SimulatedWorker do
  @moduledoc "Runs the durable deployment workflow without external side effects."

  use Oban.Worker,
    queue: :deployments,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:args], states: :incomplete]

  alias Nixploy.Deployments

  @stages [
    preparing: "Preparing deployment",
    building: "Building Nix OCI image",
    deploying: "Deploying image to target",
    verifying: "Verifying service health",
    succeeded: "Deployment succeeded"
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"deployment_id" => deployment_id}}) do
    deployment = Deployments.get_deployment!(deployment_id)

    cond do
      deployment.state in [:succeeded, :failed, :cancelled] ->
        :ok

      deployment.cancellation_requested_at ->
        cancel(deployment)

      true ->
        run_remaining_stages(deployment)
    end
  end

  defp run_remaining_stages(deployment) do
    @stages
    |> stages_after(deployment.state)
    |> Enum.reduce_while(:ok, fn {stage, message}, :ok ->
      if Deployments.cancellation_requested?(deployment.id) do
        {:halt, cancel(Deployments.get_deployment!(deployment.id))}
      else
        case Deployments.transition(deployment.id, stage, message) do
          {:ok, _deployment, _event} ->
            maybe_delay(stage)
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, inspect(reason)}}
        end
      end
    end)
  end

  defp stages_after(stages, current_state) do
    case Enum.find_index(stages, fn {state, _message} -> state == current_state end) do
      nil -> stages
      index -> Enum.drop(stages, index + 1)
    end
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

  defp maybe_delay(:succeeded), do: :ok

  defp maybe_delay(_stage) do
    Process.sleep(Application.get_env(:nixploy, :simulated_deployment_step_ms, 750))
  end
end
