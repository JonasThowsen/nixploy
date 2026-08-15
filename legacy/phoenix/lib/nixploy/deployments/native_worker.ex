defmodule Nixploy.Deployments.NativeWorker do
  @moduledoc "Runs one persisted local-store input through the native local executor."

  use Oban.Worker,
    queue: :deployments,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:args], states: :incomplete]

  alias Nixploy.Deployments.{
    NativeDeployment,
    NativeExecutor,
    NativeTargetLease,
    RemoteCliExecutor,
    RemoteStatus
  }

  alias Nixploy.NativeDeployments

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"native_deployment_id" => id}}) do
    deployment = NativeDeployments.get_deployment!(id)

    cond do
      NativeDeployment.terminal?(deployment) ->
        :ok

      deployment.cancellation_requested_at && deployment.state == :queued ->
        cancel(id)

      deployment.cancellation_requested_at ->
        reconcile_cancellation(deployment)

      true ->
        execute_or_reconcile(deployment)
    end
  rescue
    error ->
      _ = NativeDeployments.fail(id, {:worker_exception, Exception.message(error)})
      {:error, Exception.message(error)}
  end

  defp execute_or_reconcile(deployment) do
    executor = Application.get_env(:nixploy, :native_deployment_executor, NativeExecutor)

    if executor == RemoteCliExecutor and deployment.state != :queued do
      reconcile(deployment)
    else
      with_target_lease(deployment, executor)
    end
  end

  defp reconcile(deployment) do
    status = Application.get_env(:nixploy, :remote_status_probe, RemoteStatus)

    case status.observe(deployment) do
      {:ok, %{"converged" => true} = observation} ->
        case NativeDeployments.reconcile_success(deployment.id, observation) do
          {:ok, _deployment, _event} -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:ok, observation} ->
        _ =
          NativeDeployments.fail(
            deployment.id,
            {:interrupted_remote_state, safe_observation(observation)}
          )

        :ok

      {:error, reason} ->
        _ = NativeDeployments.fail(deployment.id, {:remote_reconciliation_failed, reason})
        :ok
    end
  end

  defp reconcile_cancellation(deployment) do
    status = Application.get_env(:nixploy, :remote_status_probe, RemoteStatus)

    case status.observe(deployment) do
      {:ok, observation} ->
        safe = safe_observation(observation)

        transition_cancelled(deployment.id, %{
          "code" => "cancelled_after_remote_reconciliation",
          "message" => "Cancellation reconciled against current remote identity",
          "observation" => safe
        })

      {:error, reason} ->
        transition_cancelled(deployment.id, %{
          "code" => "cancelled_with_remote_state_unavailable",
          "message" => "Cancellation completed with remote identity unavailable",
          "reason" => inspect(reason)
        })
    end
  end

  defp transition_cancelled(id, failure) do
    case NativeDeployments.transition(
           id,
           :cancelled,
           failure["message"],
           %{failure: failure, metadata: failure}
         ) do
      {:ok, _deployment, _event} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp with_target_lease(deployment, executor) do
    case NativeTargetLease.acquire(deployment.resource_prefix, deployment.id) do
      {:ok, lease} ->
        try do
          with {:ok, deployment} <-
                 NativeDeployments.assign_fencing_token(deployment.id, lease.fencing_token) do
            execute(deployment, executor, lease)
          end
        after
          NativeTargetLease.release(lease)
        end

      {:error, :target_busy} ->
        {:snooze, 10}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp execute(deployment, executor, lease) do
    stage = fn state, message, attrs ->
      with :ok <- NativeTargetLease.maintain(lease) do
        case NativeDeployments.transition(deployment.id, state, message, attrs) do
          {:ok, _deployment, _event} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end

    cancelled? = fn ->
      NativeTargetLease.maintain(lease) != :ok or
        NativeDeployments.cancellation_requested?(deployment.id)
    end

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

  defp safe_observation(observation) do
    Map.take(observation, [
      "container_verified",
      "ingress_available",
      "active_port",
      "expected_port",
      "healthy",
      "converged"
    ])
  end

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
