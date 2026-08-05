defmodule Nixploy.NativeDeployments do
  @moduledoc "Durable orchestration for native local blue/green deployments."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Deployments.{DeploymentInput, NativeDeployment, NativeEvent, ResourceIdentity}
  alias Nixploy.{Audit, Notifications, Repo}

  @history_limit 50
  @event_limit 100

  @allowed_transitions %{
    queued: [:preparing, :failed, :cancelled],
    preparing: [:building, :failed, :cancelled],
    building: [:loading, :installing_credentials, :failed, :cancelled],
    loading: [
      :installing_credentials,
      :preparing_slot,
      :pre_starting,
      :starting,
      :failed,
      :cancelled
    ],
    installing_credentials: [:loading, :preparing_slot, :failed, :cancelled],
    preparing_slot: [:pre_starting, :starting, :failed, :cancelled],
    pre_starting: [:starting, :failed, :cancelled],
    starting: [:health_checking, :verifying, :failed, :cancelled],
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
    |> preload([:requested_by_operator, :deployment_input, :rollback_of])
    |> Repo.all()
  end

  def list_for_input(input_id) do
    NativeDeployment
    |> where([deployment], deployment.deployment_input_id == ^input_id)
    |> order_by([deployment], desc: deployment.inserted_at)
    |> limit(^@history_limit)
    |> preload([:requested_by_operator, :deployment_input, :rollback_of])
    |> Repo.all()
  end

  def get_deployment!(id) do
    NativeDeployment
    |> Repo.get!(id)
    |> Repo.preload([:requested_by_operator, :deployment_input, :rollback_of])
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
          target: target,
          resource_prefix: ResourceIdentity.derive!(project, target)
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
            "target" => deployment.target,
            "resource_key" => deployment.resource_prefix
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

        {:ok, Repo.preload(deployment, [:requested_by_operator, :deployment_input, :rollback_of]),
         job}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def request_rollback(target_id, opts \\ []) do
    operator = Keyword.get(opts, :operator)
    worker = Keyword.get(opts, :worker, Nixploy.Deployments.NativeWorker)

    result =
      Multi.new()
      |> Multi.run(:target, fn repo, _changes ->
        target = repo |> locked(target_id) |> repo.preload(:deployment_input)

        with :ok <- validate_rollback_target(target),
             :ok <- ensure_rollback_changes_state(repo, target) do
          {:ok, target}
        end
      end)
      |> Multi.insert(:deployment, fn %{target: target} ->
        NativeDeployment.create_changeset(%NativeDeployment{}, %{
          deployment_input_id: target.deployment_input_id,
          requested_by_operator_id: operator_id(operator),
          project: target.project,
          target: target.target,
          operation_kind: :rollback,
          rollback_of_id: target.id,
          expected_image_id: target.image_id,
          expected_slot: target.selected_slot,
          resource_prefix: ResourceIdentity.derive!(target.project, target.target)
        })
      end)
      |> Multi.insert(:event, fn %{deployment: deployment, target: target} ->
        NativeEvent.changeset(%NativeEvent{}, %{
          native_deployment_id: deployment.id,
          stage: "queued",
          message: "Rollback to verified native operation #{target.id} queued",
          metadata: rollback_identity(target),
          inserted_at: DateTime.utc_now()
        })
      end)
      |> Multi.insert(:audit, fn %{deployment: deployment, target: target} ->
        Audit.changeset(operator, :native_rollback_queued, :native_deployment, deployment.id,
          outcome: :requested,
          metadata: Map.put(rollback_identity(target), "rollback_of_id", target.id)
        )
      end)
      |> Oban.insert(:job, fn %{deployment: deployment} ->
        worker.new(%{native_deployment_id: deployment.id})
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{deployment: deployment, job: job}} ->
        publish(deployment.id)

        {:ok, Repo.preload(deployment, [:requested_by_operator, :deployment_input, :rollback_of]),
         job}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def rollback_status(%NativeDeployment{} = target) do
    with :ok <- validate_rollback_target(target),
         :ok <- ensure_rollback_changes_state(Repo, target) do
      :available
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
      |> Multi.run(:audit, fn repo, %{deployment: deployment} ->
        if NativeDeployment.terminal?(deployment) do
          deployment.requested_by_operator_id
          |> Audit.changeset(
            terminal_audit_action(deployment),
            :native_deployment,
            deployment.id,
            outcome: terminal_audit_outcome(deployment.state),
            metadata: terminal_audit_metadata(deployment)
          )
          |> repo.insert()
        else
          {:ok, nil}
        end
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

    transition(id, :failed, "Native deployment failed: #{failure["message"]}", %{
      failure: failure
    })
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

  defp validate_rollback_target(%NativeDeployment{
         state: :succeeded,
         image_id: image_id,
         selected_slot: slot,
         selected_port: port,
         verified_upstream: upstream,
         deployment_input: %DeploymentInput{} = input
       })
       when is_binary(image_id) and slot in ["blue", "green"] and is_integer(port) and
              is_binary(upstream) do
    if Enum.all?(
         [input.store_path, input.nar_hash, input.configuration_digest],
         &(is_binary(&1) and &1 != "")
       ) do
      :ok
    else
      {:error, :rollback_identity_incomplete}
    end
  end

  defp validate_rollback_target(%NativeDeployment{state: state}) when state != :succeeded,
    do: {:error, {:rollback_target_not_succeeded, state}}

  defp validate_rollback_target(_deployment), do: {:error, :rollback_identity_incomplete}

  defp ensure_rollback_changes_state(repo, target) do
    current =
      NativeDeployment
      |> where(
        [deployment],
        deployment.project == ^target.project and deployment.target == ^target.target and
          deployment.state == :succeeded
      )
      |> order_by([deployment], desc: deployment.finished_at, desc: deployment.inserted_at)
      |> limit(1)
      |> repo.one()

    if current && same_verified_identity?(current, target),
      do: {:error, {:rollback_already_active, current.id}},
      else: :ok
  end

  defp same_verified_identity?(left, right) do
    left.deployment_input_id == right.deployment_input_id and left.image_id == right.image_id and
      left.selected_slot == right.selected_slot and
      left.verified_upstream == right.verified_upstream
  end

  defp rollback_identity(target) do
    %{
      "deployment_input_id" => target.deployment_input_id,
      "store_path" => target.deployment_input.store_path,
      "nar_hash" => target.deployment_input.nar_hash,
      "configuration_digest" => target.deployment_input.configuration_digest,
      "image_id" => target.image_id,
      "slot" => target.selected_slot,
      "upstream" => target.verified_upstream
    }
  end

  defp validate_native_config(%{"project" => project, "target" => target})
       when is_binary(project) and is_map(target) do
    references = target["credential_references"] || %{}

    if is_map(references),
      do: {:ok, {project, target["name"]}},
      else: {:error, :invalid_derived_snapshot}
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

  defp terminal_audit_action(%{operation_kind: :rollback, state: :succeeded}),
    do: :native_rollback_succeeded

  defp terminal_audit_action(%{operation_kind: :rollback, state: :failed}),
    do: :native_rollback_failed

  defp terminal_audit_action(%{operation_kind: :rollback, state: :cancelled}),
    do: :native_rollback_cancelled

  defp terminal_audit_action(%{state: :succeeded}), do: :native_deployment_succeeded
  defp terminal_audit_action(%{state: :failed}), do: :native_deployment_failed
  defp terminal_audit_action(%{state: :cancelled}), do: :native_deployment_cancelled

  defp terminal_audit_outcome(:succeeded), do: :succeeded
  defp terminal_audit_outcome(:failed), do: :failed
  defp terminal_audit_outcome(:cancelled), do: :cancelled

  defp terminal_audit_metadata(deployment) do
    %{
      "deployment_input_id" => deployment.deployment_input_id,
      "rollback_of_id" => deployment.rollback_of_id,
      "image_id" => deployment.image_id,
      "selected_slot" => deployment.selected_slot,
      "verified_upstream" => deployment.verified_upstream,
      "failure_code" => deployment.failure && deployment.failure["code"]
    }
  end

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
