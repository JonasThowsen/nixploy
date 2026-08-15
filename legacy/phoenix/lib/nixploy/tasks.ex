defmodule Nixploy.Tasks do
  @moduledoc "Durable flake-declared operational task requests."

  import Ecto.Query
  alias Ecto.Multi
  alias Nixploy.{Audit, Notifications, Repo}
  alias Nixploy.Deployments.NativeDeployment
  alias Nixploy.Tasks.{TaskOperation, Worker}

  def list_for_deployment(deployment_id) do
    TaskOperation
    |> where([operation], operation.native_deployment_id == ^deployment_id)
    |> order_by([operation], desc: operation.inserted_at)
    |> limit(50)
    |> preload(:requested_by_operator)
    |> Repo.all()
  end

  def get!(id),
    do: TaskOperation |> Repo.get!(id) |> Repo.preload(native_deployment: :deployment_input)

  def enqueue(deployment_id, task_name, confirmed_name, operator, opts \\ []) do
    worker = Keyword.get(opts, :worker, Worker)

    result =
      Multi.new()
      |> Multi.run(:deployment, fn repo, _changes ->
        deployment =
          NativeDeployment
          |> repo.get(deployment_id)
          |> repo.preload(:deployment_input)

        cond do
          is_nil(deployment) -> {:error, :deployment_not_found}
          deployment.state != :succeeded -> {:error, :deployment_not_succeeded}
          true -> {:ok, deployment}
        end
      end)
      |> Multi.run(:task, fn _repo, %{deployment: deployment} ->
        tasks = get_in(deployment.deployment_input.derived_snapshot, ["target", "tasks"]) || %{}

        case Map.fetch(tasks, task_name) do
          {:ok, task} when confirmed_name == task_name -> {:ok, task}
          {:ok, _task} -> {:error, :task_confirmation_mismatch}
          :error -> {:error, :task_not_declared}
        end
      end)
      |> Multi.insert(:operation, fn %{deployment: deployment, task: task} ->
        TaskOperation.create_changeset(%TaskOperation{}, %{
          native_deployment_id: deployment.id,
          deployment_input_id: deployment.deployment_input_id,
          requested_by_operator_id: operator.id,
          task_name: task_name,
          description: task["description"],
          confirmation: task["confirmation"],
          command_digest: digest(task["command"]),
          resource_key: deployment.resource_prefix,
          state: :queued
        })
      end)
      |> Multi.insert(:audit, fn %{operation: operation} ->
        Audit.changeset(operator, :task_operation_queued, :task_operation, operation.id,
          outcome: :requested,
          metadata: %{
            "native_deployment_id" => deployment_id,
            "task_name" => task_name,
            "command_digest" => operation.command_digest,
            "resource_key" => operation.resource_key
          }
        )
      end)
      |> Oban.insert(:job, fn %{operation: operation} ->
        worker.new(%{task_operation_id: operation.id})
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{operation: operation, job: job}} ->
        {:ok, Repo.preload(operation, :requested_by_operator), job}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def request_cancellation(id) do
    operation = Repo.get!(TaskOperation, id)

    if operation.state in [:queued, :running] do
      operation
      |> TaskOperation.update_changeset(%{cancellation_requested_at: DateTime.utc_now()})
      |> Repo.update()
    else
      {:error, :task_terminal}
    end
  end

  def mark_running(operation) do
    operation
    |> TaskOperation.update_changeset(%{state: :running, started_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def finish(operation, state, evidence, failure \\ nil) do
    operation = Repo.preload(operation, :requested_by_operator)

    attrs = %{
      state: state,
      output_tail: evidence.output_tail,
      output_truncated: evidence.output_truncated,
      failure: failure,
      finished_at: DateTime.utc_now()
    }

    result =
      Multi.new()
      |> Multi.update(:operation, TaskOperation.update_changeset(operation, attrs))
      |> Multi.insert(:audit, fn %{operation: completed} ->
        Audit.changeset(
          completed.requested_by_operator,
          :task_operation_finished,
          :task_operation,
          completed.id,
          outcome: if(state == :succeeded, do: :succeeded, else: :failed),
          metadata: %{
            "task_name" => completed.task_name,
            "command_digest" => completed.command_digest,
            "resource_key" => completed.resource_key,
            "output_truncated" => completed.output_truncated
          }
        )
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{operation: completed}} ->
        Notifications.publish(completed.native_deployment_id)
        {:ok, completed}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def cancelled?(id) do
    from(operation in TaskOperation,
      where: operation.id == ^id,
      select: not is_nil(operation.cancellation_requested_at)
    )
    |> Repo.one()
  end

  defp digest(argv), do: :crypto.hash(:sha256, Jason.encode!(argv)) |> Base.encode16(case: :lower)
end
