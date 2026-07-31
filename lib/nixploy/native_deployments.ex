defmodule Nixploy.NativeDeployments do
  @moduledoc "Durable orchestration for native local blue/green deployments."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Deployments.{DeploymentInput, NativeDeployment, NativeEvent}
  alias Nixploy.{Audit, Notifications, Repo}

  @history_limit 50
  @event_limit 100

  @allowed_transitions %{
    queued: [:preparing, :failed, :cancelled],
    preparing: [:building, :failed, :cancelled],
    building: [:loading, :failed, :cancelled],
    loading: [:preparing_slot, :failed, :cancelled],
    preparing_slot: [:starting, :failed, :cancelled],
    starting: [:health_checking, :failed, :cancelled],
    health_checking: [:switching, :failed, :cancelled],
    switching: [:verifying, :failed, :cancelled],
    verifying: [:succeeded, :failed, :cancelled],
    succeeded: [],
    failed: [],
    cancelled: []
  }

  def list_deployments do
    NativeDeployment
    |> order_by([deployment], desc: deployment.inserted_at)
    |> limit(^@history_limit)
    |> preload([:requested_by_operator, :deployment_input])
    |> Repo.all()
  end

  def list_for_input(input_id) do
    NativeDeployment
    |> where([deployment], deployment.deployment_input_id == ^input_id)
    |> order_by([deployment], desc: deployment.inserted_at)
    |> limit(^@history_limit)
    |> preload([:requested_by_operator, :deployment_input])
    |> Repo.all()
  end

  def get_deployment!(id) do
    NativeDeployment
    |> Repo.get!(id)
    |> Repo.preload([:requested_by_operator, :deployment_input])
  end

  def list_events(id) do
    NativeEvent
    |> where([event], event.native_deployment_id == ^id)
    |> order_by([event], desc: event.id)
    |> limit(^@event_limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def enqueue(input_id, opts \\ []) do
    operator = Keyword.get(opts, :operator)
    worker = Keyword.get(opts, :worker, Nixploy.Deployments.NativeWorker)

    result =
      Multi.new()
      |> Multi.run(:input, fn repo, _changes ->
        case repo.get(DeploymentInput, input_id) do
          %DeploymentInput{state: :staged} = input -> {:ok, input}
          %DeploymentInput{state: state} -> {:error, {:input_not_staged, state}}
          nil -> {:error, :deployment_input_not_found}
        end
      end)
      |> Multi.run(:native_config, fn _repo, %{input: input} ->
        validate_native_config(input.derived_snapshot)
      end)
      |> Multi.insert(:deployment, fn %{input: input, native_config: {project, target}} ->
        NativeDeployment.create_changeset(%NativeDeployment{}, %{
          deployment_input_id: input.id,
          requested_by_operator_id: operator_id(operator),
          project: project,
          target: target
        })
      end)
      |> Multi.insert(:event, fn %{deployment: deployment} ->
        NativeEvent.changeset(%NativeEvent{}, %{
          native_deployment_id: deployment.id,
          stage: "queued",
          message: "Native deployment queued",
          inserted_at: DateTime.utc_now()
        })
      end)
      |> Multi.insert(:audit, fn %{deployment: deployment, input: input} ->
        Audit.changeset(operator, :native_deployment_queued, :native_deployment, deployment.id,
          outcome: :requested,
          metadata: %{
            "deployment_input_id" => input.id,
            "store_path" => input.store_path,
            "nar_hash" => input.nar_hash,
            "configuration_digest" => input.configuration_digest,
            "project" => deployment.project,
            "target" => deployment.target
          }
        )
      end)
      |> Oban.insert(:job, fn %{deployment: deployment} ->
        worker.new(%{native_deployment_id: deployment.id})
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{deployment: deployment, job: job}} ->
        publish(deployment.id)
        {:ok, Repo.preload(deployment, [:requested_by_operator, :deployment_input]), job}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def transition(id, next_state, message, attrs \\ %{})
      when is_atom(next_state) and is_binary(message) do
    attrs = Map.new(attrs)
    now = DateTime.utc_now()

    result =
      Multi.new()
      |> Multi.run(:deployment, fn repo, _changes ->
        deployment = locked(repo, id)

        cond do
          deployment.cancellation_requested_at && next_state not in [:cancelled, :failed] ->
            {:error, :cancellation_requested}

          next_state in Map.fetch!(@allowed_transitions, deployment.state) ->
            transition_attrs =
              attrs
              |> Map.put(:state, next_state)
              |> Map.put(:current_stage, next_state)
              |> maybe_started(deployment, now)
              |> maybe_finished(next_state, now)

            deployment
            |> NativeDeployment.transition_changeset(transition_attrs)
            |> repo.update()

          true ->
            {:error, {:invalid_transition, deployment.state, next_state}}
        end
      end)
      |> Multi.insert(:event, fn %{deployment: deployment} ->
        NativeEvent.changeset(%NativeEvent{}, %{
          native_deployment_id: deployment.id,
          stage: Atom.to_string(next_state),
          level: event_level(next_state),
          message: message,
          metadata: Map.get(attrs, :metadata, %{}),
          inserted_at: now
        })
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{deployment: deployment, event: event}} ->
        publish(id)
        {:ok, deployment, event}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def fail(id, reason) do
    failure = Nixploy.Deployments.NativeExecutor.failure(reason)

    case transition(id, :failed, "Native deployment failed: #{failure["message"]}", %{
           failure: failure
         }) do
      {:ok, deployment, event} ->
        _ =
          Audit.record(nil, :native_deployment_failed, :native_deployment, id,
            outcome: :failed,
            metadata: %{"failure_code" => failure["code"]}
          )

        {:ok, deployment, event}

      error ->
        error
    end
  end

  def request_cancellation(id, opts \\ []) do
    operator = Keyword.get(opts, :operator)
    now = DateTime.utc_now()

    result =
      Multi.new()
      |> Multi.run(:deployment, fn repo, _changes ->
        deployment = locked(repo, id)

        if NativeDeployment.terminal?(deployment) do
          {:error, {:terminal, deployment.state}}
        else
          deployment
          |> NativeDeployment.cancellation_changeset(now)
          |> repo.update()
        end
      end)
      |> Multi.insert(:event, fn %{deployment: deployment} ->
        NativeEvent.changeset(%NativeEvent{}, %{
          native_deployment_id: deployment.id,
          stage: Atom.to_string(deployment.current_stage),
          level: :warning,
          message: "Cancellation requested",
          inserted_at: now
        })
      end)
      |> Multi.insert(:audit, fn %{deployment: deployment} ->
        Audit.changeset(operator, :cancellation_requested, :native_deployment, deployment.id,
          outcome: :requested
        )
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{deployment: deployment, event: event}} ->
        publish(id)
        {:ok, deployment, event}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def cancellation_requested?(id) do
    NativeDeployment
    |> where([deployment], deployment.id == ^id)
    |> select([deployment], not is_nil(deployment.cancellation_requested_at))
    |> Repo.one!()
  end

  defp validate_native_config(%{"project" => project, "target" => target})
       when is_binary(project) and is_map(target) do
    cond do
      target["secrets_declared"] -> {:error, :native_secrets_not_supported}
      target["pre_start_declared"] -> {:error, :native_pre_start_not_supported}
      true -> {:ok, {project, target["name"]}}
    end
  end

  defp validate_native_config(_snapshot), do: {:error, :invalid_derived_snapshot}

  defp locked(repo, id) do
    NativeDeployment
    |> where([deployment], deployment.id == ^id)
    |> lock("FOR UPDATE")
    |> repo.one!()
  end

  defp maybe_started(attrs, %{started_at: nil}, now), do: Map.put(attrs, :started_at, now)
  defp maybe_started(attrs, _deployment, _now), do: attrs

  defp maybe_finished(attrs, state, now) when state in [:succeeded, :failed, :cancelled],
    do: Map.put(attrs, :finished_at, now)

  defp maybe_finished(attrs, _state, _now), do: attrs

  defp event_level(:failed), do: :error
  defp event_level(:cancelled), do: :warning
  defp event_level(_state), do: :info

  defp operator_id(%{id: id}), do: id
  defp operator_id(id) when is_binary(id), do: id
  defp operator_id(nil), do: nil

  defp publish(id) do
    _ = Notifications.publish(id)
    :ok
  end
end
