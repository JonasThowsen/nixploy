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
    |> preload([:requested_by_operator, :deployment_input, :rollback_of, :retry_of])
    |> Repo.all()
  end

  def list_for_input(input_id) do
    NativeDeployment
    |> where([deployment], deployment.deployment_input_id == ^input_id)
    |> order_by([deployment], desc: deployment.inserted_at)
    |> limit(^@history_limit)
    |> preload([:requested_by_operator, :deployment_input, :rollback_of, :retry_of])
    |> Repo.all()
  end

  def get_deployment!(id) do
    NativeDeployment
    |> Repo.get!(id)
    |> Repo.preload([:requested_by_operator, :deployment_input, :rollback_of, :retry_of])
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

  def retry(id, opts \\ []) do
    operator = Keyword.get(opts, :operator)
    worker = Keyword.get(opts, :worker, Nixploy.Deployments.NativeWorker)

    result =
      Multi.new()
      |> Multi.run(:previous, fn repo, _changes ->
        previous = locked(repo, id)

        if previous.state in [:failed, :cancelled],
          do: {:ok, previous},
          else: {:error, {:retry_not_terminal_failure, previous.state}}
      end)
      |> Multi.insert(:deployment, fn %{previous: previous} ->
        NativeDeployment.create_changeset(%NativeDeployment{}, %{
          deployment_input_id: previous.deployment_input_id,
          requested_by_operator_id: operator_id(operator),
          project: previous.project,
          target: previous.target,
          operation_kind: previous.operation_kind,
          resource_prefix: previous.resource_prefix,
          retry_of_id: previous.id,
          rollback_of_id: previous.rollback_of_id,
          expected_image_id: previous.expected_image_id,
          expected_slot: previous.expected_slot
        })
      end)
      |> Multi.insert(:event, fn %{deployment: deployment, previous: previous} ->
        NativeEvent.changeset(%NativeEvent{}, %{
          native_deployment_id: deployment.id,
          stage: "queued",
          message: "Exact immutable retry of native operation #{previous.id} queued",
          metadata: %{
            "retry_of_id" => previous.id,
            "deployment_input_id" => previous.deployment_input_id
          },
          inserted_at: DateTime.utc_now()
        })
      end)
      |> Multi.insert(:audit, fn %{deployment: deployment, previous: previous} ->
        Audit.changeset(operator, :native_deployment_retried, :native_deployment, deployment.id,
          outcome: :requested,
          metadata: %{
            "retry_of_id" => previous.id,
            "deployment_input_id" => previous.deployment_input_id,
            "resource_key" => previous.resource_prefix
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
        {:ok, get_deployment!(deployment.id), job}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def assign_fencing_token(id, token) when is_integer(token) and token > 0 do
    now = DateTime.utc_now()

    result =
      Multi.new()
      |> Multi.run(:deployment, fn repo, _changes ->
        repo
        |> locked(id)
        |> NativeDeployment.transition_changeset(%{fencing_token: token})
        |> repo.update()
      end)
      |> Multi.insert(:event, fn %{deployment: deployment} ->
        NativeEvent.changeset(%NativeEvent{}, %{
          native_deployment_id: deployment.id,
          stage: "fencing",
          message: "Exclusive target fencing lease acquired",
          metadata: %{"fencing_token" => token, "resource_key" => deployment.resource_prefix},
          inserted_at: now
        })
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{deployment: deployment}} ->
        publish(id)
        {:ok, get_deployment!(deployment.id)}

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

  def enqueue_status_refresh(id, operator, opts \\ []) do
    worker = Keyword.get(opts, :worker, Nixploy.Deployments.RemoteStatusWorker)
    deployment = get_deployment!(id)

    result =
      Multi.new()
      |> Multi.insert(
        :audit,
        Audit.changeset(operator, :remote_status_requested, :native_deployment, id,
          outcome: :requested,
          metadata: %{"resource_key" => deployment.resource_prefix}
        )
      )
      |> Oban.insert(:job, worker.new(%{remote_status_deployment_id: id}))
      |> Repo.transaction()

    case result do
      {:ok, %{job: job}} -> {:ok, job}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def record_remote_observation(id, observation) when is_map(observation) do
    metadata =
      Map.take(observation, [
        "project",
        "target",
        "connection",
        "target_identity",
        "container_verified",
        "container_id",
        "container_name",
        "container_state",
        "container_status",
        "image_reference",
        "image_id",
        "revision",
        "deployed_at",
        "ingress_available",
        "active_slot",
        "active_port",
        "expected_port",
        "caddy_route_id",
        "caddy_proxy_id",
        "caddy_upstream",
        "target_local_health",
        "public_health",
        "metrics",
        "observed_at",
        "healthy",
        "converged",
        "error"
      ])

    message =
      cond do
        is_binary(metadata["error"]) -> "Remote status refresh failed"
        metadata["converged"] -> "Remote runtime matches the exact deployment identity"
        true -> "Remote runtime does not match the exact deployment identity"
      end

    result =
      %NativeEvent{}
      |> NativeEvent.changeset(%{
        native_deployment_id: id,
        stage: "observation",
        level: if(metadata["converged"], do: :info, else: :warning),
        message: message,
        metadata: metadata,
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    case result do
      {:ok, event} ->
        publish(id)
        {:ok, event}

      error ->
        error
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

  def reconcile_success(id, observation) when is_map(observation) do
    now = DateTime.utc_now()

    result =
      Multi.new()
      |> Multi.run(:deployment, fn repo, _changes ->
        deployment = locked(repo, id)

        cond do
          NativeDeployment.terminal?(deployment) ->
            {:error, {:terminal, deployment.state}}

          observation["converged"] != true ->
            {:error, :remote_state_not_converged}

          true ->
            attrs = %{
              state: :succeeded,
              current_stage: :succeeded,
              container_id: observation["container_id"] || deployment.container_id,
              image_id: observation["image_id"] || deployment.image_id,
              verified_upstream:
                if(is_integer(observation["active_port"]),
                  do: "127.0.0.1:#{observation["active_port"]}",
                  else: deployment.verified_upstream
                ),
              started_at: deployment.started_at || now,
              finished_at: now
            }

            deployment |> NativeDeployment.transition_changeset(attrs) |> repo.update()
        end
      end)
      |> Multi.insert(:event, fn %{deployment: deployment} ->
        NativeEvent.changeset(%NativeEvent{}, %{
          native_deployment_id: deployment.id,
          stage: "reconciliation",
          level: "info",
          message: "Reconciled interrupted worker from independent remote identity",
          metadata: %{
            "container_id" => observation["container_id"],
            "image_id" => observation["image_id"],
            "active_port" => observation["active_port"]
          },
          inserted_at: now
        })
      end)
      |> Multi.insert(:audit, fn %{deployment: deployment} ->
        Audit.changeset(
          deployment.requested_by_operator_id,
          :native_deployment_reconciled,
          :native_deployment,
          deployment.id,
          outcome: :succeeded,
          metadata: terminal_audit_metadata(deployment)
        )
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{deployment: deployment, event: event}} ->
        publish(id)
        {:ok, deployment, event}

      {:error, _step, reason, _changes} ->
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
