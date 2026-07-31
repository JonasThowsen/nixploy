defmodule Nixploy.Deployments do
  @moduledoc "Durable deployment requests, transitions, cancellation, and events."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Deployments.{Deployment, DeploymentInput, Event, LocalStoreInput, Output, Spec}
  alias Nixploy.{Audit, Notifications, Repo}

  @history_limit 50
  @input_history_limit 50
  @event_limit 100
  @output_bytes 65_536

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
    |> limit(^@history_limit)
    |> preload([:output, :requested_by_operator, service: [:repository, :target]])
    |> Repo.all()
  end

  def get_deployment!(id) do
    Deployment
    |> Repo.get!(id)
    |> Repo.preload([:output, :requested_by_operator, service: [:repository, :target]])
  end

  def list_deployment_inputs do
    DeploymentInput
    |> order_by([input], desc: input.inserted_at)
    |> limit(^@input_history_limit)
    |> preload(:requested_by_operator)
    |> Repo.all()
  end

  def get_deployment_input!(id) do
    DeploymentInput
    |> Repo.get!(id)
    |> Repo.preload(:requested_by_operator)
  end

  def inspect_local_store(store_path, opts \\ []) do
    local_store_probe(store_path, opts)
  end

  def stage_local_store(attrs, opts \\ []) do
    operator = Keyword.get(opts, :operator)
    store_path = attr(attrs, :store_path)
    selected_target = attr(attrs, :selected_target)
    expected_nar_hash = attr(attrs, :expected_nar_hash)

    case create_deployment_input(store_path, selected_target, operator) do
      {:ok, input} ->
        complete_local_store_staging(
          input,
          expected_nar_hash,
          operator,
          Keyword.delete(opts, :operator)
        )

      {:error, _reason} = error ->
        error
    end
  end

  def list_events(deployment_id) do
    Event
    |> where([event], event.deployment_id == ^deployment_id)
    |> order_by([event], desc: event.id)
    |> limit(^@event_limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def create_deployment(attrs, opts \\ []) do
    attrs
    |> deployment_multi(Keyword.get(opts, :operator))
    |> Repo.transaction()
    |> unwrap_created_deployment()
    |> publish_result()
  end

  def enqueue_deployment(attrs, opts \\ []) do
    worker = Keyword.get(opts, :worker, deployment_worker())
    operator = Keyword.get(opts, :operator)

    result =
      attrs
      |> deployment_multi(operator, Keyword.get(opts, :service_snapshot))
      |> Oban.insert(:job, fn %{deployment: deployment} ->
        worker.new(%{deployment_id: deployment.id})
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{deployment: deployment, event: event, job: job}} ->
          {:ok, deployment, event, job}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end

    case result do
      {:ok, deployment, event, job} ->
        publish(deployment.id)
        {:ok, deployment, event, job}

      error ->
        error
    end
  end

  def transition(deployment_id, next_state, message, attrs \\ %{})
      when is_atom(next_state) and is_binary(message) do
    now = now()
    attrs = Map.new(attrs)

    Multi.new()
    |> Multi.run(:deployment, fn repo, _changes ->
      deployment = locked_deployment(repo, deployment_id)

      cond do
        deployment.cancellation_requested_at && next_state not in [:cancelled, :failed] ->
          {:error, :cancellation_requested}

        next_state in Map.fetch!(@allowed_transitions, deployment.state) ->
          transition_attrs =
            attrs
            |> Map.put(:state, next_state)
            |> Map.put(:current_stage, next_state)
            |> maybe_put_started_at(deployment, now)
            |> maybe_put_finished_at(next_state, now)

          deployment
          |> Deployment.transition_changeset(transition_attrs)
          |> repo.update()

        true ->
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
    |> publish_result()
  end

  def retry_deployment(deployment_id, opts \\ []) do
    deployment = get_deployment!(deployment_id)

    cond do
      not Deployment.terminal?(deployment) ->
        {:error, {:not_terminal, deployment.state}}

      is_nil(deployment.resolved_commit) ->
        {:error, :unresolved_deployment}

      true ->
        enqueue_deployment(
          %{
            service_id: deployment.service_id,
            requested_ref: deployment.resolved_commit,
            retry_of_deployment_id: deployment.id
          },
          Keyword.put(opts, :service_snapshot, deployment.service_snapshot)
        )
    end
  end

  def request_cancellation(deployment_id, opts \\ []) do
    now = now()
    operator = Keyword.get(opts, :operator)

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
        |> Deployment.cancellation_changeset(now, operator_id(operator))
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
    |> Multi.insert(:audit, fn %{deployment: deployment} ->
      Audit.changeset(operator, :cancellation_requested, :deployment, deployment.id,
        outcome: :requested
      )
    end)
    |> Repo.transaction()
    |> unwrap_transaction()
    |> publish_result()
  end

  def cancellation_requested?(deployment_id) do
    Deployment
    |> where([deployment], deployment.id == ^deployment_id)
    |> select([deployment], not is_nil(deployment.cancellation_requested_at))
    |> Repo.one!()
  end

  def record_event(deployment_id, stage, level, message, metadata \\ %{}) do
    result =
      %Event{}
      |> Event.changeset(%{
        deployment_id: deployment_id,
        stage: stage,
        level: level,
        message: message,
        metadata: metadata
      })
      |> Repo.insert()

    case result do
      {:ok, event} ->
        publish(deployment_id)
        {:ok, event}

      error ->
        error
    end
  end

  def reset_output(deployment_id) do
    attrs = %{deployment_id: deployment_id, content: "", line_count: 0, truncated: false}

    %Output{}
    |> Output.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [content: "", line_count: 0, truncated: false, updated_at: now()]],
      conflict_target: :deployment_id
    )
  end

  def append_output(deployment_id, content, line_count)
      when is_binary(content) and is_integer(line_count) and line_count >= 0 do
    result =
      Repo.transaction(fn ->
        output =
          Output
          |> where([output], output.deployment_id == ^deployment_id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

        combined = output.content <> content
        {retained, truncated_now?} = bounded_tail(combined, @output_bytes)

        output
        |> Output.changeset(%{
          content: retained,
          line_count: output.line_count + line_count,
          truncated: output.truncated or truncated_now?
        })
        |> Repo.update!()
      end)

    case result do
      {:ok, output} ->
        publish(deployment_id)
        {:ok, output}

      error ->
        error
    end
  end

  def change_deployment(%Deployment{} = deployment, attrs \\ %{}) do
    Deployment.create_changeset(deployment, attrs)
  end

  defp create_deployment_input(store_path, selected_target, operator) do
    started_at = DateTime.utc_now()

    Multi.new()
    |> Multi.insert(
      :deployment_input,
      DeploymentInput.create_changeset(%DeploymentInput{}, %{
        input_kind: :local_store,
        store_path: store_path,
        selected_target: selected_target,
        requested_by_operator_id: operator_id(operator),
        started_at: started_at
      })
    )
    |> Multi.insert(:audit, fn %{deployment_input: input} ->
      Audit.changeset(operator, :local_store_staging_requested, :deployment_input, input.id,
        outcome: :requested,
        metadata: %{
          "input_kind" => "local_store",
          "store_path" => input.store_path,
          "selected_target" => input.selected_target
        }
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{deployment_input: input}} -> {:ok, input}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  defp complete_local_store_staging(input, expected_nar_hash, operator, opts) do
    with {:ok, source} <- local_store_probe(input.store_path, opts),
         :ok <- verify_nar_hash(expected_nar_hash, source.nar_hash),
         {:ok, _target, snapshot} <-
           LocalStoreInput.select_target(source, input.selected_target) do
      persist_staged_input(input, source.nar_hash, snapshot, operator)
    else
      {:error, reason} -> persist_failed_input(input, reason, operator)
    end
  end

  defp persist_staged_input(input, nar_hash, snapshot, operator) do
    finished_at = DateTime.utc_now()
    selected_target = get_in(snapshot, ["target", "name"])
    configuration_digest = LocalStoreInput.digest(snapshot)

    result =
      Multi.new()
      |> Multi.run(:locked_input, fn repo, _changes ->
        {:ok, locked_deployment_input(repo, input.id)}
      end)
      |> Multi.update(:deployment_input, fn %{locked_input: locked_input} ->
        DeploymentInput.staged_changeset(locked_input, %{
          nar_hash: nar_hash,
          selected_target: selected_target,
          derived_snapshot: snapshot,
          configuration_digest: configuration_digest,
          state: :staged,
          finished_at: finished_at
        })
      end)
      |> Multi.insert(:audit, fn %{deployment_input: staged_input} ->
        Audit.changeset(
          operator,
          :local_store_staged,
          :deployment_input,
          staged_input.id,
          metadata: %{
            "input_kind" => "local_store",
            "store_path" => staged_input.store_path,
            "nar_hash" => staged_input.nar_hash,
            "selected_target" => staged_input.selected_target,
            "configuration_digest" => staged_input.configuration_digest
          }
        )
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{deployment_input: staged_input}} ->
        # TODO(tracer): Slice 1.2 must dispatch this persisted local-store input
        # to a native executor; staging intentionally enqueues no deployment job.
        # TODO(tracer): Operator-side Nix closure transport must be added before
        # store paths from another machine can be staged safely.
        # TODO(tracer): The native executor must build and load the declared image
        # into the nixploy user's Podman store without touching root's store.
        # TODO(tracer): The native executor must identify and replace only the
        # inactive managed slot after failing closed on unmanaged collisions.
        # TODO(tracer): The candidate must pass the exact persisted health path
        # before any ingress mutation is permitted.
        # TODO(tracer): Caddy switching and independent readback belong to Slice
        # 1.2 and must preserve the previously routed slot on every failure.
        # TODO(tracer): Rollback must create a new operation referencing an exact
        # previously healthy store path, NAR hash, image, digest, and slot.
        {:ok, Repo.preload(staged_input, :requested_by_operator)}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp persist_failed_input(input, reason, operator) do
    failure = LocalStoreInput.failure(reason)

    result =
      Multi.new()
      |> Multi.run(:locked_input, fn repo, _changes ->
        {:ok, locked_deployment_input(repo, input.id)}
      end)
      |> Multi.update(:deployment_input, fn %{locked_input: locked_input} ->
        DeploymentInput.failed_changeset(locked_input, %{
          state: :failed,
          failure: failure,
          finished_at: DateTime.utc_now()
        })
      end)
      |> Multi.insert(:audit, fn %{deployment_input: failed_input} ->
        Audit.changeset(
          operator,
          :local_store_staging_failed,
          :deployment_input,
          failed_input.id,
          outcome: :failed,
          metadata: %{
            "input_kind" => "local_store",
            "store_path" => failed_input.store_path,
            "selected_target" => failed_input.selected_target,
            "failure_code" => failure["code"]
          }
        )
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{deployment_input: failed_input}} ->
        {:error, Repo.preload(failed_input, :requested_by_operator)}

      {:error, _operation, transition_reason, _changes} ->
        {:error, transition_reason}
    end
  end

  defp verify_nar_hash(nil, _actual), do: :ok
  defp verify_nar_hash("", _actual), do: :ok
  defp verify_nar_hash(hash, hash), do: :ok

  defp verify_nar_hash(expected, actual),
    do: {:error, {:nar_hash_changed, expected, actual}}

  defp locked_deployment_input(repo, input_id) do
    DeploymentInput
    |> where([input], input.id == ^input_id)
    |> lock("FOR UPDATE")
    |> repo.one!()
  end

  defp local_store_probe(store_path, opts) do
    case Application.get_env(:nixploy, :local_store_input_probe, LocalStoreInput) do
      probe when is_function(probe, 2) -> probe.(store_path, opts)
      probe when is_function(probe, 1) -> probe.(store_path)
      module -> module.probe(store_path, opts)
    end
  end

  defp attr(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp deployment_multi(attrs, operator, snapshot_override \\ nil) do
    attrs = normalize_attrs(attrs)
    service_id = attrs[:service_id]

    Multi.new()
    |> Multi.run(:service, fn repo, _changes ->
      case repo.get(Nixploy.Applications.Service, service_id) do
        nil -> {:error, :service_not_found}
        service -> {:ok, repo.preload(service, [:repository, :target])}
      end
    end)
    |> Multi.insert(:deployment, fn %{service: service} ->
      attrs =
        attrs
        |> Map.put(:service_snapshot, snapshot_override || Spec.snapshot(service))
        |> Map.put(:requested_by_operator_id, operator_id(operator))

      Deployment.create_changeset(%Deployment{}, attrs)
    end)
    |> Multi.insert(:event, fn %{deployment: deployment} ->
      Event.changeset(%Event{}, %{
        deployment_id: deployment.id,
        stage: "queued",
        message: "Deployment queued"
      })
    end)
    |> Multi.insert(:audit, fn %{deployment: deployment} ->
      Audit.changeset(operator, :queued, :deployment, deployment.id,
        outcome: :requested,
        metadata: %{
          "requested_ref" => deployment.requested_ref,
          "target_id" => Spec.target_id(deployment.service_snapshot)
        }
      )
    end)
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

  defp unwrap_created_deployment({:ok, %{deployment: deployment, event: event}}),
    do: {:ok, deployment, event}

  defp unwrap_created_deployment({:error, _operation, reason, _changes}), do: {:error, reason}

  defp unwrap_transaction({:ok, %{deployment: deployment, event: event}}),
    do: {:ok, deployment, event}

  defp unwrap_transaction({:error, _operation, reason, _changes}), do: {:error, reason}

  defp publish_result({:ok, deployment, _event} = result) do
    publish(deployment.id)
    result
  end

  defp publish_result(error), do: error

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp bounded_tail(output, limit) when byte_size(output) <= limit, do: {output, false}

  defp bounded_tail(output, limit) do
    retained = binary_part(output, byte_size(output) - limit, limit)

    retained =
      case :binary.split(retained, "\n") do
        [_partial] -> retained
        [_partial, complete] -> complete
      end

    {String.replace_invalid(retained, "�"), true}
  end

  defp operator_id(%{id: id}), do: id
  defp operator_id(id) when is_binary(id), do: id
  defp operator_id(nil), do: nil

  defp publish(deployment_id) do
    _ = Notifications.publish(deployment_id)
    :ok
  end

  defp deployment_worker do
    Application.get_env(:nixploy, :deployment_worker, Nixploy.Deployments.Worker)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
