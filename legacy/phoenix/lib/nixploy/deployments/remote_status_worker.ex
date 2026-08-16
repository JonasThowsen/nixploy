defmodule Nixploy.Deployments.RemoteStatusWorker do
  use Oban.Worker,
    queue: :health_checks,
    max_attempts: 1,
    unique: [period: 30, fields: [:args], states: :incomplete]

  alias Nixploy.Deployments.RemoteStatus
  alias Nixploy.NativeDeployments

  @impl true
  def perform(%Oban.Job{args: %{"remote_status_deployment_id" => id}}) do
    deployment = NativeDeployments.get_deployment!(id)
    probe = Application.get_env(:nixploy, :remote_status_probe, RemoteStatus)

    case probe.observe(deployment) do
      {:ok, observation} ->
        NativeDeployments.record_remote_observation(id, observation)

      {:error, reason} ->
        NativeDeployments.record_remote_observation(id, %{
          "error" => inspect(reason, limit: 10, printable_limit: 1_000),
          "converged" => false
        })
    end

    :ok
  end
end
