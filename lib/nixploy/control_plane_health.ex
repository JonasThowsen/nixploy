defmodule Nixploy.ControlPlaneHealth do
  @moduledoc "Web-safe control-plane readiness derived from PostgreSQL and host-owned configuration."

  import Ecto.Query, warn: false

  alias Nixploy.Deployments.DeploymentInput
  alias Nixploy.{ManagedApplications, Repo, RuntimeRole, WorkerHeartbeat}

  def snapshot do
    applications = ManagedApplications.list()
    latest = latest_inputs(Enum.map(applications, & &1.key))
    workers = WorkerHeartbeat.active()

    %{
      database: database_readiness(),
      web: %{ready?: true, role: RuntimeRole.current()},
      workers: %{
        active_count: length(workers),
        singleton?: length(workers) == 1,
        latest: List.first(workers)
      },
      backup: backup_readiness(),
      queues: queue_state(),
      repositories:
        Enum.map(applications, fn application ->
          input = latest[application.key]

          %{
            key: application.key,
            identity: application.repository_identity,
            state: repository_state(input),
            observed_at: input && (input.finished_at || input.requested_at),
            error: input && input.failure && input.failure["message"]
          }
        end),
      package_version: package_version()
    }
  end

  defp database_readiness do
    case Repo.query("SELECT current_database(), current_setting('server_version')", []) do
      {:ok, %{rows: [[database, version]]}} ->
        %{ready?: true, database: database, version: version}

      {:error, _reason} ->
        %{ready?: false, database: nil, version: nil}
    end
  end

  defp queue_state do
    counts =
      from(job in Oban.Job,
        where: job.state in ["available", "scheduled", "executing", "retryable"],
        group_by: job.state,
        select: {job.state, count(job.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      available: counts["available"] || 0,
      scheduled: counts["scheduled"] || 0,
      executing: counts["executing"] || 0,
      retryable: counts["retryable"] || 0
    }
  end

  defp latest_inputs([]), do: %{}

  defp latest_inputs(keys) do
    DeploymentInput
    |> where([input], input.application_key in ^keys)
    |> order_by([input], desc: input.inserted_at)
    |> Repo.all()
    |> Enum.reduce(%{}, fn input, acc -> Map.put_new(acc, input.application_key, input) end)
  end

  defp repository_state(nil), do: :not_observed
  defp repository_state(%DeploymentInput{state: :staged}), do: :available
  defp repository_state(%DeploymentInput{state: :staging}), do: :preparing
  defp repository_state(%DeploymentInput{state: :failed}), do: :unavailable

  defp backup_readiness do
    %{
      enabled?: System.get_env("NIXPLOY_BACKUP_ENABLED") == "true",
      schedule: System.get_env("NIXPLOY_BACKUP_SCHEDULE")
    }
  end

  defp package_version do
    case Application.spec(:nixploy, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end
end
