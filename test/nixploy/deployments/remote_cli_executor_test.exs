defmodule Nixploy.Deployments.RemoteCliExecutorTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.{DeploymentInput, NativeDeployment, RemoteCliExecutor}
  alias Nixploy.Execution.Result

  @source "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source"
  @revision String.duplicate("b", 40)
  @digest String.duplicate("c", 64)

  test "invokes only the packaged CLI with complete immutable identity and a private workspace" do
    root =
      Path.join(System.tmp_dir!(), "nixploy-remote-cli-#{System.unique_integer([:positive])}")

    parent = self()
    on_exit(fn -> File.rm_rf(root) end)

    execute = fn command, opts ->
      send(parent, {:command, command, File.stat!(command.cd).mode})
      opts[:on_line].(event(1, "terminal", "succeeded", "succeeded", "ok"))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end

    assert :ok =
             RemoteCliExecutor.deploy(deployment(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy",
               workspace_root: root,
               plan: allow_plan(),
               policy: allow_policy()
             )

    assert_receive {:command, command, mode}
    assert Bitwise.band(mode, 0o777) == 0o700
    assert command.executable == "/nix/store/cli/bin/nixploy"
    assert command.cd == Path.join(root, deployment().id)
    assert command.timeout == :timer.hours(1)
    assert command.max_output_bytes == 1_114_112

    assert command.args == [
             "deploy",
             "--target",
             "production",
             "--source",
             @source,
             "--git-revision",
             @revision,
             "--repository-identity",
             "fixture/repository",
             "--configuration-digest",
             @digest,
             "--operation-id",
             deployment().id,
             "--resource-key",
             "nixploy-fixture-bab0990cab-production",
             "--events",
             "jsonl"
           ]

    refute File.exists?(command.cd)
  end

  test "fails before invocation when immutable Git identity is absent" do
    deployment = put_in(deployment().deployment_input.source_revision, nil)

    assert_raise ArgumentError, ~r/persisted full Git revision/, fn ->
      RemoteCliExecutor.command(deployment, "/tmp/workspace",
        executable: "/nix/store/cli/bin/nixploy"
      )
    end
  end

  test "drives durable stages only from ordered protocol events" do
    parent = self()

    stages =
      ~w(building installing_credentials loading preparing_slot starting health_checking switching verifying)a

    execute = fn _command, opts ->
      opts[:on_line].("human diagnostic")

      stages
      |> Enum.with_index(1)
      |> Enum.each(fn {stage, sequence} ->
        opts[:on_line].(event(sequence, "stage", Atom.to_string(stage), nil, nil))
      end)

      opts[:on_line].(event(9, "terminal", "succeeded", "succeeded", "ok"))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end

    stage = fn state, _message, attrs ->
      send(parent, {:stage, state, attrs})
      :ok
    end

    root =
      Path.join(System.tmp_dir!(), "nixploy-remote-cli-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    assert :ok =
             RemoteCliExecutor.deploy(deployment(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy",
               workspace_root: root,
               stage: stage,
               plan: allow_plan(),
               policy: allow_policy()
             )

    assert_receive {:stage, :preparing,
                    %{metadata: %{policy_code: "allowed", fresh_plan_digest: digest}}}

    assert byte_size(digest) == 64
    assert_receive {:stage, :verifying, %{}}
    assert_receive {:stage, :succeeded, %{}}
  end

  test "fails closed on malformed or incomplete protocol" do
    execute = fn _command, opts ->
      opts[:on_line].(event(2, "stage", "preparing", nil, nil))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end

    root =
      Path.join(System.tmp_dir!(), "nixploy-remote-cli-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, {:remote_cli_protocol_error, 0, :invalid_event_sequence}} =
             RemoteCliExecutor.deploy(deployment(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy",
               workspace_root: root,
               plan: allow_plan(),
               policy: allow_policy()
             )
  end

  test "fails closed when output exceeds the adapter bound" do
    execute = fn _command, _opts ->
      {:ok, %Result{exit_status: 0, output_tail: "tail", output_truncated?: true}}
    end

    root =
      Path.join(System.tmp_dir!(), "nixploy-remote-cli-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, :remote_cli_output_too_large} =
             RemoteCliExecutor.deploy(deployment(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy",
               workspace_root: root,
               plan: allow_plan(),
               policy: allow_policy()
             )
  end

  defp allow_plan do
    fn _deployment ->
      {:ok,
       %{
         "schema" => "nixploy.plan/v1",
         "operation_id" => deployment().id,
         "resource_key" => "nixploy-fixture-bab0990cab-production"
       }}
    end
  end

  defp allow_policy do
    fn _deployment ->
      {:ok,
       %{
         allow?: true,
         mode: :enforce,
         code: "allowed",
         payload_digest: String.duplicate("d", 64),
         component_digest: String.duplicate("e", 64)
       }}
    end
  end

  defp event(sequence, type, stage, status, code) do
    Jason.encode!(%{
      "schema" => "nixploy.event/v1",
      "seq" => sequence,
      "type" => type,
      "stage" => stage,
      "code" => code,
      "message" => "event message",
      "operation_id" => deployment().id,
      "status" => status,
      "artifacts" => %{}
    })
  end

  defp deployment do
    %NativeDeployment{
      id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      project: "fixture",
      target: "production",
      deployment_input: %DeploymentInput{
        store_path: @source,
        source_revision: @revision,
        source_repository: "fixture/repository",
        configuration_digest: @digest
      }
    }
  end
end
