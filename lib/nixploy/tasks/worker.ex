defmodule Nixploy.Tasks.Worker do
  use Oban.Worker,
    queue: :deployments,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:args], states: :incomplete]

  alias Nixploy.Tasks
  alias Nixploy.Tasks.RemoteExecutor

  @impl true
  def perform(%Oban.Job{args: %{"task_operation_id" => id}}) do
    operation = Tasks.get!(id)

    cond do
      operation.state in [:succeeded, :failed, :cancelled] ->
        :ok

      operation.cancellation_requested_at ->
        cancel(operation)

      true ->
        run(operation)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp run(operation) do
    deployment = operation.native_deployment

    task =
      get_in(deployment.deployment_input.derived_snapshot, [
        "target",
        "tasks",
        operation.task_name
      ])

    with true <- is_map(task) or {:error, :task_not_declared},
         true <-
           digest(task["command"]) == operation.command_digest or {:error, :task_command_changed},
         {:ok, running} <- Tasks.mark_running(operation) do
      executor = Application.get_env(:nixploy, :task_executor, RemoteExecutor)
      cancelled? = fn -> Tasks.cancelled?(running.id) end

      case executor.run(running, deployment, task, cancelled?: cancelled?) do
        {:ok, evidence} ->
          case Tasks.finish(running, :succeeded, evidence) do
            {:ok, _operation} -> :ok
            {:error, changeset} -> {:error, inspect(changeset.errors)}
          end

        {:error, :cancelled, evidence} ->
          finish_cancelled(running, evidence)

        {:error, reason, evidence} ->
          failure = %{"code" => "task_failed", "message" => safe_reason(reason)}

          case Tasks.finish(running, :failed, evidence, failure) do
            {:ok, _operation} -> :ok
            {:error, changeset} -> {:error, inspect(changeset.errors)}
          end

        {:error, reason} ->
          failure = %{"code" => "task_failed", "message" => safe_reason(reason)}
          evidence = %{output_tail: "", output_truncated: false}
          _ = Tasks.finish(running, :failed, evidence, failure)
          :ok
      end
    else
      {:error, reason} ->
        failure = %{"code" => "task_invalid", "message" => safe_reason(reason)}
        _ = Tasks.finish(operation, :failed, %{output_tail: "", output_truncated: false}, failure)
        :ok
    end
  end

  defp cancel(operation),
    do: finish_cancelled(operation, %{output_tail: "", output_truncated: false})

  defp finish_cancelled(operation, evidence) do
    case Tasks.finish(operation, :cancelled, evidence) do
      {:ok, _operation} -> :ok
      {:error, changeset} -> {:error, inspect(changeset.errors)}
    end
  end

  defp digest(argv), do: :crypto.hash(:sha256, Jason.encode!(argv)) |> Base.encode16(case: :lower)
  defp safe_reason(reason), do: inspect(reason, limit: 10, printable_limit: 1_000)
end
