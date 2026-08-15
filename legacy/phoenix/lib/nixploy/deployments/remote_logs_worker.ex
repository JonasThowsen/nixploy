defmodule Nixploy.Deployments.RemoteLogsWorker do
  use Oban.Worker,
    queue: :health_checks,
    max_attempts: 1,
    unique: [period: 30, fields: [:args], states: :incomplete]

  alias Nixploy.Deployments.RemoteLogs
  alias Nixploy.{NativeDeployments, Runtime}

  @impl true
  def perform(%Oban.Job{
        args: %{
          "application_key" => application_key,
          "native_deployment_id" => deployment_id,
          "request_id" => request_id
        }
      }) do
    deployment = NativeDeployments.get_deployment!(deployment_id)
    probe = Application.get_env(:nixploy, :remote_logs_probe, RemoteLogs)

    result =
      case probe.read(deployment) do
        {:ok, snapshot} ->
          Runtime.complete_logs(application_key, request_id, %{
            content: snapshot["content"],
            line_count: snapshot["line_count"],
            truncated: snapshot["truncated"]
          })

        {:error, reason} ->
          Runtime.fail_logs(application_key, request_id, reason)
      end

    case result do
      {:ok, _snapshot} -> :ok
      {:error, :stale_request} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
