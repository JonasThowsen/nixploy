defmodule Nixploy.Tasks.RemoteExecutorTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.{DeploymentInput, NativeDeployment}
  alias Nixploy.Execution.Result
  alias Nixploy.Tasks.{RemoteExecutor, TaskOperation}

  defmodule Policy do
    def evaluate(_deployment, operation: :task),
      do: {:ok, %{allow?: true}}
  end

  test "invokes only the packaged CLI with declared task name and exact deployed image" do
    root = Path.join(System.tmp_dir!(), "nixploy-task-#{System.unique_integer([:positive])}")
    parent = self()
    on_exit(fn -> File.rm_rf(root) end)

    execute = fn command, opts ->
      send(parent, {:command, command})
      opts[:on_line].(event(1, "stage", "starting", nil, nil))
      opts[:on_line].("bounded task output")
      opts[:on_line].(event(2, "terminal", "succeeded", "succeeded", "ok"))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end

    assert {:ok, evidence} =
             RemoteExecutor.run(operation(), deployment(), task(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy",
               workspace_root: root,
               policy: Policy
             )

    assert evidence.output_tail == "bounded task output\n"
    assert_receive {:command, command}
    assert command.executable == "/nix/store/cli/bin/nixploy"
    assert command.timeout == 150_000

    assert command.args == [
             "task",
             "--target",
             "production",
             "--task",
             "refresh-search",
             "--source",
             deployment().deployment_input.store_path,
             "--git-revision",
             deployment().deployment_input.source_revision,
             "--repository-identity",
             "fixture/repository",
             "--configuration-digest",
             deployment().deployment_input.configuration_digest,
             "--operation-id",
             operation().id,
             "--resource-key",
             operation().resource_key,
             "--image-reference",
             "fixture:latest",
             "--image-id",
             deployment().image_id,
             "--events",
             "jsonl"
           ]
  end

  defp event(seq, type, stage, status, code) do
    Jason.encode!(%{
      "schema" => "nixploy.event/v1",
      "seq" => seq,
      "type" => type,
      "stage" => stage,
      "code" => code,
      "message" => "task event",
      "operation_id" => operation().id,
      "status" => status,
      "artifacts" => %{}
    })
  end

  defp task,
    do: %{
      "command" => ["/app/bin/task", "refresh-search"],
      "timeout_seconds" => 120
    }

  defp operation do
    %TaskOperation{
      id: "11111111-2222-4333-8444-555555555555",
      task_name: "refresh-search",
      resource_key: "nixploy-fixture-bab0990cab-production"
    }
  end

  defp deployment do
    %NativeDeployment{
      target: "production",
      image_reference: "fixture:latest",
      image_id: "sha256:" <> String.duplicate("a", 64),
      deployment_input: %DeploymentInput{
        store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source",
        source_revision: String.duplicate("b", 40),
        source_repository: "fixture/repository",
        configuration_digest: String.duplicate("c", 64)
      }
    }
  end
end
