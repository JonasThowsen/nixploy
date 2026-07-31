defmodule Nixploy.Deployments.NativeWorker do
  @moduledoc "Runs one persisted local-store input through the native local executor."

  use Oban.Worker,
    queue: :deployments,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:args], states: :incomplete]

  alias Nixploy.Deployments.{NativeDeployment, NativeExecutor}
  alias Nixploy.NativeDeployments

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"native_deployment_id" => id}}) do
    deployment = NativeDeployments.get_deployment!(id)

    cond do
      NativeDeployment.terminal?(deployment) ->
        :ok

      deployment.cancellation_requested_at ->
        cancel(id)

      true ->
        execute(deployment)
    end
  rescue
    error ->
      _ = NativeDeployments.fail(id, {:worker_exception, Exception.message(error)})
      {:error, Exception.message(error)}
  end

  defp execute(deployment) do
    stage = fn state, message, attrs ->
      case NativeDeployments.transition(deployment.id, state, message, attrs) do
        {:ok, _deployment, _event} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    cancelled? = fn -> NativeDeployments.cancellation_requested?(deployment.id) end

    executor = Application.get_env(:nixploy, :native_deployment_executor, NativeExecutor)

    case executor.deploy(deployment, stage: stage, cancelled?: cancelled?) do
      :ok ->
        :ok

      {:error, :cancelled} ->
        cancel(deployment.id)

      {:error, :cancellation_requested} ->
        cancel(deployment.id)

      {:error, reason} ->
        case NativeDeployments.fail(deployment.id, reason) do
          {:ok, _deployment, _event} -> :ok
          {:error, transition_reason} -> {:error, inspect(transition_reason)}
        end
    end
  end

  # TODO(tracer): Slice 1.3 must reconcile identified Podman/Caddy side effects
  # before classifying interrupted cancellation as clean or intervention-required.
  defp cancel(id) do
    case NativeDeployments.transition(
           id,
           :cancelled,
           "Native deployment cancelled; inspect persisted runtime evidence"
         ) do
      {:ok, _deployment, _event} ->
        :ok

      {:error, {:invalid_transition, state, :cancelled}}
      when state in [:succeeded, :failed, :cancelled] ->
        :ok

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
