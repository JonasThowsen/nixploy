defmodule Nixploy.Deployments do
  @moduledoc "Durable deployment requests, transitions, cancellation, and events."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Deployments.{Deployment, Event, Output, Spec}
  alias Nixploy.{Audit, Notifications, Repo}

  @history_limit 50
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
