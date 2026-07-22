defmodule Nixploy.Operations do
  @moduledoc "Worker-owned service observations and operational jobs."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Notifications
  alias Nixploy.Operations.{LogWorker, ServiceLogSnapshot, ServiceObservation, StatusWorker}
  alias Nixploy.Repo

  def list_service_observations do
    ServiceObservation
    |> Repo.all()
  end

  def get_service_observation(service_id) do
    Repo.get_by(ServiceObservation, service_id: service_id)
  end

  def list_service_log_snapshots do
    ServiceLogSnapshot
    |> Repo.all()
  end

  def get_service_log_snapshot(service_id) do
    Repo.get_by(ServiceLogSnapshot, service_id: service_id)
  end

  def request_status_refresh(service_id) do
    now = now()

    result =
      Multi.new()
      |> Multi.run(:service, fn repo, _changes -> locked_service(repo, service_id) end)
      |> Multi.run(:observation, fn repo, %{service: service} ->
        request_observation(repo, service, now)
      end)
      |> Oban.insert(:job, fn %{service: service} ->
        StatusWorker.new(%{service_id: service.id})
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{observation: observation, job: job}} ->
        publish_status(service_id)
        {:ok, observation, job}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def request_log_snapshot(service_id) do
    now = now()

    result =
      Multi.new()
      |> Multi.run(:service, fn repo, _changes -> locked_service(repo, service_id) end)
      |> Multi.run(:observation, fn repo, %{service: service} ->
        request_observation(repo, service, now)
      end)
      |> Multi.run(:snapshot, fn repo, %{service: service} ->
        case repo.get_by(ServiceLogSnapshot, service_id: service.id) do
          nil ->
            %ServiceLogSnapshot{}
            |> ServiceLogSnapshot.request_changeset(%{
              service_id: service.id,
              requested_at: now
            })
            |> repo.insert()

          snapshot ->
            snapshot
            |> ServiceLogSnapshot.request_changeset(%{requested_at: now})
            |> repo.update()
        end
      end)
      |> Oban.insert(:job, fn %{service: service} ->
        LogWorker.new(%{service_id: service.id})
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{snapshot: snapshot, job: job}} ->
        publish_logs(service_id)
        {:ok, snapshot, job}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def complete_status_refresh(service_id, attrs) do
    service_id
    |> observation_changeset(
      &ServiceObservation.available_changeset(&1, Map.put(attrs, :refreshed_at, now()))
    )
    |> publish_result(service_id)
  end

  def fail_status_refresh(service_id, reason) do
    attrs = %{failure: %{message: failure_message(reason)}, refreshed_at: now()}

    service_id
    |> observation_changeset(&ServiceObservation.failed_changeset(&1, attrs))
    |> publish_result(service_id)
  end

  def complete_log_snapshot(service_id, attrs) do
    service_id
    |> snapshot_changeset(
      &ServiceLogSnapshot.available_changeset(&1, Map.put(attrs, :fetched_at, now()))
    )
    |> publish_log_result(service_id)
  end

  def fail_log_snapshot(service_id, reason) do
    attrs = %{failure: %{message: failure_message(reason)}, fetched_at: now()}

    service_id
    |> snapshot_changeset(&ServiceLogSnapshot.failed_changeset(&1, attrs))
    |> publish_log_result(service_id)
  end

  defp observation_changeset(service_id, changeset_fun) do
    case Repo.get_by(ServiceObservation, service_id: service_id) do
      nil -> {:error, :observation_not_found}
      observation -> observation |> changeset_fun.() |> Repo.update()
    end
  end

  defp snapshot_changeset(service_id, changeset_fun) do
    case Repo.get_by(ServiceLogSnapshot, service_id: service_id) do
      nil -> {:error, :log_snapshot_not_found}
      snapshot -> snapshot |> changeset_fun.() |> Repo.update()
    end
  end

  defp publish_result({:ok, _observation} = result, service_id) do
    publish_status(service_id)
    result
  end

  defp publish_result(error, _service_id), do: error

  defp publish_log_result({:ok, _snapshot} = result, service_id) do
    publish_logs(service_id)
    result
  end

  defp publish_log_result(error, _service_id), do: error

  defp locked_service(repo, service_id) do
    service =
      Nixploy.Applications.Service
      |> where([service], service.id == ^service_id)
      |> lock("FOR UPDATE")
      |> repo.one()

    if service, do: {:ok, service}, else: {:error, :not_found}
  end

  defp request_observation(repo, service, now) do
    case repo.get_by(ServiceObservation, service_id: service.id) do
      nil ->
        %ServiceObservation{}
        |> ServiceObservation.request_changeset(%{
          service_id: service.id,
          requested_at: now
        })
        |> repo.insert()

      observation ->
        observation
        |> ServiceObservation.request_changeset(%{requested_at: now})
        |> repo.update()
    end
  end

  defp publish_status(service_id) do
    _ = Notifications.publish_service_status(service_id)
    :ok
  end

  defp publish_logs(service_id) do
    _ = Notifications.publish_service_logs(service_id)
    :ok
  end

  defp failure_message(reason) when is_binary(reason), do: reason
  defp failure_message(reason), do: inspect(reason)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
