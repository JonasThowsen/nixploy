defmodule Nixploy.Operations do
  @moduledoc "Worker-owned service observations and operational jobs."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Notifications
  alias Nixploy.Operations.{ServiceObservation, StatusWorker}
  alias Nixploy.Repo

  def list_service_observations do
    ServiceObservation
    |> Repo.all()
  end

  def get_service_observation(service_id) do
    Repo.get_by(ServiceObservation, service_id: service_id)
  end

  def request_status_refresh(service_id) do
    now = now()

    result =
      Multi.new()
      |> Multi.run(:service, fn repo, _changes ->
        service =
          Nixploy.Applications.Service
          |> where([service], service.id == ^service_id)
          |> lock("FOR UPDATE")
          |> repo.one()

        if service, do: {:ok, service}, else: {:error, :not_found}
      end)
      |> Multi.run(:observation, fn repo, %{service: service} ->
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
      end)
      |> Oban.insert(:job, fn %{service: service} ->
        StatusWorker.new(%{service_id: service.id})
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{observation: observation, job: job}} ->
        publish(service_id)
        {:ok, observation, job}

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

  defp observation_changeset(service_id, changeset_fun) do
    case Repo.get_by(ServiceObservation, service_id: service_id) do
      nil -> {:error, :observation_not_found}
      observation -> observation |> changeset_fun.() |> Repo.update()
    end
  end

  defp publish_result({:ok, _observation} = result, service_id) do
    publish(service_id)
    result
  end

  defp publish_result(error, _service_id), do: error

  defp publish(service_id) do
    _ = Notifications.publish_service_status(service_id)
    :ok
  end

  defp failure_message(reason) when is_binary(reason), do: reason
  defp failure_message(reason), do: inspect(reason)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
