defmodule Nixploy.Deployments do
  @moduledoc "Durable deployment requests, transitions, cancellation, and events."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Deployments.{Deployment, Event}
  alias Nixploy.Repo

  @allowed_transitions %{
    queued: [:preparing, :failed, :cancelled],
    preparing: [:building, :failed, :cancelled],
    building: [:deploying, :failed, :cancelled],
    deploying: [:verifying, :failed, :cancelled],
    verifying: [:succeeded, :failed, :cancelled],
    succeeded: [],
    failed: [],
    cancelled: []
  }

  def list_deployments do
    Deployment
    |> order_by([deployment], desc: deployment.inserted_at)
    |> preload(service: [:repository, :target])
    |> Repo.all()
  end

  def get_deployment!(id) do
    Deployment
    |> Repo.get!(id)
    |> Repo.preload(service: [:repository, :target])
  end

  def list_events(deployment_id) do
    Event
    |> where([event], event.deployment_id == ^deployment_id)
    |> order_by([event], asc: event.id)
    |> Repo.all()
  end

  def create_deployment(attrs) do
    Multi.new()
    |> Multi.insert(:deployment, Deployment.create_changeset(%Deployment{}, attrs))
    |> Multi.insert(:event, fn %{deployment: deployment} ->
      Event.changeset(%Event{}, %{
        deployment_id: deployment.id,
        stage: "queued",
        message: "Deployment queued"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{deployment: deployment, event: event}} -> {:ok, deployment, event}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  def transition(deployment_id, next_state, message, attrs \\ %{})
      when is_atom(next_state) and is_binary(message) do
    now = now()
    attrs = Map.new(attrs)

    Multi.new()
    |> Multi.run(:deployment, fn repo, _changes ->
      deployment = locked_deployment(repo, deployment_id)

      if next_state in Map.fetch!(@allowed_transitions, deployment.state) do
        transition_attrs =
          attrs
          |> Map.put(:state, next_state)
          |> Map.put(:current_stage, next_state)
          |> maybe_put_started_at(deployment, now)
          |> maybe_put_finished_at(next_state, now)

        deployment
        |> Deployment.transition_changeset(transition_attrs)
        |> repo.update()
      else
        {:error, {:invalid_transition, deployment.state, next_state}}
      end
    end)
    |> Multi.insert(:event, fn %{deployment: deployment} ->
      Event.changeset(%Event{}, %{
        deployment_id: deployment.id,
        stage: Atom.to_string(next_state),
        level: event_level(next_state),
        message: message,
        metadata: Map.get(attrs, :metadata, %{})
      })
    end)
    |> Repo.transaction()
    |> unwrap_transaction()
  end

  def request_cancellation(deployment_id) do
    now = now()

    Multi.new()
    |> Multi.run(:locked_deployment, fn repo, _changes ->
      deployment = locked_deployment(repo, deployment_id)

      if Deployment.terminal?(deployment) do
        {:error, {:terminal, deployment.state}}
      else
        {:ok, deployment}
      end
    end)
    |> Multi.run(:deployment, fn repo, %{locked_deployment: deployment} ->
      if deployment.cancellation_requested_at do
        {:ok, deployment}
      else
        deployment
        |> Deployment.cancellation_changeset(now)
        |> repo.update()
      end
    end)
    |> Multi.run(:event, fn repo,
                            %{
                              locked_deployment: locked_deployment,
                              deployment: deployment
                            } ->
      if locked_deployment.cancellation_requested_at do
        {:ok, nil}
      else
        %Event{}
        |> Event.changeset(%{
          deployment_id: deployment.id,
          level: :warning,
          stage: Atom.to_string(deployment.current_stage),
          message: "Cancellation requested"
        })
        |> repo.insert()
      end
    end)
    |> Repo.transaction()
    |> unwrap_transaction()
  end

  def cancellation_requested?(deployment_id) do
    Deployment
    |> where([deployment], deployment.id == ^deployment_id)
    |> select([deployment], not is_nil(deployment.cancellation_requested_at))
    |> Repo.one!()
  end

  def change_deployment(%Deployment{} = deployment, attrs \\ %{}) do
    Deployment.create_changeset(deployment, attrs)
  end

  defp locked_deployment(repo, deployment_id) do
    Deployment
    |> where([deployment], deployment.id == ^deployment_id)
    |> lock("FOR UPDATE")
    |> repo.one!()
  end

  defp maybe_put_started_at(attrs, %{started_at: nil}, now),
    do: Map.put(attrs, :started_at, now)

  defp maybe_put_started_at(attrs, _deployment, _now), do: attrs

  defp maybe_put_finished_at(attrs, state, now) when state in [:succeeded, :failed, :cancelled],
    do: Map.put(attrs, :finished_at, now)

  defp maybe_put_finished_at(attrs, _state, _now), do: attrs

  defp event_level(:failed), do: :error
  defp event_level(:cancelled), do: :warning
  defp event_level(_state), do: :info

  defp unwrap_transaction({:ok, %{deployment: deployment, event: event}}),
    do: {:ok, deployment, event}

  defp unwrap_transaction({:error, _operation, reason, _changes}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
