defmodule Nixploy.Operations do
  @moduledoc "Worker-owned service observations and operational jobs."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.{Audit, Notifications}
  alias Nixploy.Operations.{LogWorker, ServiceLogSnapshot, ServiceObservation, StatusWorker}
  alias Nixploy.Repo

  def list_service_observations, do: Repo.all(ServiceObservation)

  def get_service_observation(service_id),
    do: Repo.get_by(ServiceObservation, service_id: service_id)

  def list_service_log_snapshots, do: Repo.all(ServiceLogSnapshot)

  def get_service_log_snapshot(service_id),
    do: Repo.get_by(ServiceLogSnapshot, service_id: service_id)

  def request_status_refresh(service_id, opts \\ []) do
    now = now()
    request_id = Ecto.UUID.generate()
    operator = Keyword.get(opts, :operator)

    result =
      Multi.new()
      |> Multi.run(:service, fn repo, _changes -> locked_service(repo, service_id) end)
      |> Multi.run(:observation, fn repo, %{service: service} ->
        request_observation(repo, service, request_id, now)
      end)
      |> Oban.insert(:job, fn %{service: service, observation: observation} ->
        StatusWorker.new(%{service_id: service.id, request_id: observation.request_id})
      end)
      |> Multi.insert(:audit, fn %{service: service} ->
        Audit.changeset(operator, :status_requested, :service, service.id, outcome: :requested)
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

  def request_log_snapshot(service_id, opts \\ []) do
    now = now()
    request_id = Ecto.UUID.generate()
    operator = Keyword.get(opts, :operator)

    result =
      Multi.new()
      |> Multi.run(:service, fn repo, _changes -> locked_service(repo, service_id) end)
      # Logs are tied to an observation request as well, so the worker reads a
      # current active slot before collecting its bounded snapshot.
      |> Multi.run(:observation, fn repo, %{service: service} ->
        request_observation(repo, service, Ecto.UUID.generate(), now)
      end)
      |> Multi.run(:snapshot, fn repo, %{service: service} ->
        request_snapshot(repo, service, request_id, now)
      end)
      |> Oban.insert(:job, fn %{
                                service: service,
                                observation: observation,
                                snapshot: snapshot
                              } ->
        LogWorker.new(%{
          service_id: service.id,
          request_id: snapshot.request_id,
          status_request_id: observation.request_id
        })
      end)
      |> Multi.insert(:audit, fn %{service: service} ->
        Audit.changeset(operator, :logs_requested, :service, service.id, outcome: :requested)
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

  def record_status_observation(service_id, attrs) do
    now = now()
    request_id = Ecto.UUID.generate()

    result =
      Repo.transaction(fn ->
        service = locked_service!(service_id)
        observation = request_observation!(service, request_id, now)

        observation
        |> ServiceObservation.available_changeset(Map.put(attrs, :refreshed_at, now))
        |> Repo.update!()
      end)

    case result do
      {:ok, observation} ->
        publish_status(service_id)
        {:ok, observation}

      error ->
        error
    end
  end

  def complete_status_refresh(service_id, request_id, attrs) do
    service_id
    |> observation_changeset(
      request_id,
      &ServiceObservation.available_changeset(&1, Map.put(attrs, :refreshed_at, now()))
    )
    |> publish_result(service_id)
  end

  def fail_status_refresh(service_id, request_id, reason) do
    attrs = %{failure: %{message: failure_message(reason)}, refreshed_at: now()}

    service_id
    |> observation_changeset(request_id, &ServiceObservation.failed_changeset(&1, attrs))
    |> publish_result(service_id)
  end

  def complete_log_snapshot(service_id, request_id, attrs) do
    service_id
    |> snapshot_changeset(
      request_id,
      &ServiceLogSnapshot.available_changeset(&1, Map.put(attrs, :fetched_at, now()))
    )
    |> publish_log_result(service_id)
  end

  def fail_log_snapshot(service_id, request_id, reason) do
    attrs = %{failure: %{message: failure_message(reason)}, fetched_at: now()}

    service_id
    |> snapshot_changeset(request_id, &ServiceLogSnapshot.failed_changeset(&1, attrs))
    |> publish_log_result(service_id)
  end

  defp observation_changeset(service_id, request_id, changeset_fun) do
    fenced_update(ServiceObservation, service_id, request_id, changeset_fun)
  end

  defp snapshot_changeset(service_id, request_id, changeset_fun) do
    fenced_update(ServiceLogSnapshot, service_id, request_id, changeset_fun)
  end

  defp fenced_update(schema, service_id, request_id, changeset_fun) do
    Repo.transaction(fn ->
      record =
        schema
        |> where([record], record.service_id == ^service_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(record) -> Repo.rollback(:request_not_found)
        record.request_id != request_id -> Repo.rollback(:stale_request)
        true -> record |> changeset_fun.() |> Repo.update!()
      end
    end)
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, reason}
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

  defp locked_service!(service_id) do
    Nixploy.Applications.Service
    |> where([service], service.id == ^service_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp request_observation!(service, request_id, now) do
    case Repo.get_by(ServiceObservation, service_id: service.id) do
      nil ->
        %ServiceObservation{}
        |> ServiceObservation.request_changeset(%{
          service_id: service.id,
          request_id: request_id,
          requested_at: now
        })
        |> Repo.insert!()

      observation ->
        observation
        |> ServiceObservation.request_changeset(%{request_id: request_id, requested_at: now})
        |> Repo.update!()
    end
  end

  defp request_observation(repo, service, request_id, now) do
    case repo.get_by(ServiceObservation, service_id: service.id) do
      nil ->
        %ServiceObservation{}
        |> ServiceObservation.request_changeset(%{
          service_id: service.id,
          request_id: request_id,
          requested_at: now
        })
        |> repo.insert()

      observation ->
        observation
        |> ServiceObservation.request_changeset(%{request_id: request_id, requested_at: now})
        |> repo.update()
    end
  end

  defp request_snapshot(repo, service, request_id, now) do
    case repo.get_by(ServiceLogSnapshot, service_id: service.id) do
      nil ->
        %ServiceLogSnapshot{}
        |> ServiceLogSnapshot.request_changeset(%{
          service_id: service.id,
          request_id: request_id,
          requested_at: now
        })
        |> repo.insert()

      snapshot ->
        snapshot
        |> ServiceLogSnapshot.request_changeset(%{request_id: request_id, requested_at: now})
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
