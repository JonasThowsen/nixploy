defmodule Nixploy.TasksTest do
  use Nixploy.DataCase, async: false
  use Oban.Testing, repo: Nixploy.Repo

  alias Nixploy.Deployments.NativeWorker
  alias Nixploy.Execution.Result
  alias Nixploy.Tasks
  alias Nixploy.Tasks.Worker

  @store "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-task-source"
  @nar "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

  defmodule DeploymentExecutor do
    @image_id "sha256:" <> String.duplicate("a", 64)

    def deploy(_deployment, opts) do
      stage = opts[:stage]
      :ok = stage.(:preparing, "Preparing", %{})
      :ok = stage.(:building, "Building", %{})
      :ok = stage.(:loading, "Loading", %{image_reference: "fixture:latest", image_id: @image_id})
      :ok = stage.(:preparing_slot, "Slot", %{selected_slot: "blue", selected_port: 8080})
      :ok = stage.(:starting, "Starting", %{container_name: "fixture-blue"})
      :ok = stage.(:health_checking, "Health", %{container_id: "container"})
      :ok = stage.(:switching, "Switching", %{})
      :ok = stage.(:verifying, "Verifying", %{})
      stage.(:succeeded, "Succeeded", %{verified_upstream: "127.0.0.1:8080"})
    end
  end

  defmodule TaskExecutor do
    def run(_operation, _deployment, task, _opts) do
      send(self(), {:task_argv, task["command"]})
      {:ok, %{output_tail: "index refreshed\n", output_truncated: false}}
    end
  end

  setup do
    old_deploy = Application.get_env(:nixploy, :native_deployment_executor)
    old_task = Application.get_env(:nixploy, :task_executor)
    Application.put_env(:nixploy, :native_deployment_executor, DeploymentExecutor)
    Application.put_env(:nixploy, :task_executor, TaskExecutor)

    on_exit(fn ->
      restore(:native_deployment_executor, old_deploy)
      restore(:task_executor, old_task)
    end)

    :ok
  end

  test "runs only a confirmed flake-declared fixed-argv task with durable bounded output" do
    operator = Nixploy.Fixtures.operator_fixture()
    input = staged_input(operator)
    {:ok, deployment, _job} = Nixploy.NativeDeployments.enqueue(input.id, operator: operator)
    assert :ok = perform_job(NativeWorker, %{native_deployment_id: deployment.id})
    deployment = Nixploy.NativeDeployments.get_deployment!(deployment.id)

    assert {:error, :task_confirmation_mismatch} =
             Tasks.enqueue(deployment.id, "refresh-search", "wrong", operator)

    assert {:error, :task_not_declared} =
             Tasks.enqueue(deployment.id, "arbitrary", "arbitrary", operator)

    assert {:ok, operation, job} =
             Tasks.enqueue(deployment.id, "refresh-search", "refresh-search", operator)

    assert operation.resource_key == deployment.resource_prefix
    assert operation.command_digest =~ ~r/^[0-9a-f]{64}$/
    assert operation.confirmation == :required
    assert job.worker == inspect(Worker)

    assert :ok = perform_job(Worker, %{task_operation_id: operation.id})
    assert_receive {:task_argv, ["/app/bin/task", "refresh-search"]}

    [completed] = Tasks.list_for_deployment(deployment.id)
    assert completed.state == :succeeded
    assert completed.output_tail == "index refreshed\n"
    refute completed.output_truncated
  end

  defp staged_input(operator) do
    execute = fn command, _opts ->
      case command.args do
        ["path-info" | _] -> ok(Jason.encode!(%{@store => %{"narHash" => @nar}}))
        ["eval" | _] -> ok(Jason.encode!(config()))
      end
    end

    {:ok, input} =
      Nixploy.Deployments.stage_local_store(
        %{store_path: @store, selected_target: "production"},
        operator: operator,
        execute: execute,
        path_exists?: fn _path -> true end
      )

    input
  end

  defp config do
    %{
      "__schema" => "v0.3",
      "project" => "task-fixture",
      "targets" => %{
        "production" => %{
          "image" => "fixtureImage",
          "run" => %{"environment" => %{}, "network" => "host", "ports" => [], "preStart" => []},
          "secrets" => %{},
          "tasks" => %{
            "refresh-search" => %{
              "description" => "Refresh search index",
              "command" => ["/app/bin/task", "refresh-search"],
              "timeoutSeconds" => 120,
              "confirmation" => "required"
            }
          },
          "web" => %{
            "domain" => "task.invalid",
            "healthPath" => "/health",
            "slots" => %{"blue" => 8080, "green" => 8081}
          }
        }
      }
    }
  end

  defp ok(output),
    do: {:ok, %Result{exit_status: 0, output_tail: output, output_truncated?: false}}

  defp restore(key, nil), do: Application.delete_env(:nixploy, key)
  defp restore(key, value), do: Application.put_env(:nixploy, key, value)
end
