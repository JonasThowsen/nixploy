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

    execute = fn command, _opts ->
      send(parent, {:command, command, File.stat!(command.cd).mode})
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end

    assert :ok =
             RemoteCliExecutor.deploy(deployment(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy",
               workspace_root: root
             )

    assert_receive {:command, command, mode}
    assert Bitwise.band(mode, 0o777) == 0o700
    assert command.executable == "/nix/store/cli/bin/nixploy"
    assert command.cd == Path.join(root, deployment().id)
    assert command.timeout == :timer.hours(1)
    assert command.max_output_bytes == 65_536

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
             "nixploy-fixture-bab0990cab-production"
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
               workspace_root: root
             )
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
