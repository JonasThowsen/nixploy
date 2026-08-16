defmodule Nixploy.Deployments.RemoteLogsTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.{DeploymentInput, NativeDeployment, RemoteLogs}
  alias Nixploy.Execution.Result

  test "accepts one bounded managed-container snapshot and uses packaged fixed argv" do
    execute = fn command, opts ->
      send(self(), {:command, command})
      opts[:on_line].("bounded diagnostic")
      opts[:on_line].(Jason.encode!(snapshot()))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end

    assert {:ok, observed} =
             RemoteLogs.read(deployment(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy"
             )

    assert observed["content"] == "ready\nTOKEN=[REDACTED]"
    assert_receive {:command, command}
    assert command.args |> Enum.take(2) == ["logs", "--target"]
    assert Enum.take(command.args, -2) == ["--container-name", deployment().container_name]
    assert command.max_output_bytes == 65_536
  end

  test "rejects wrong container, unredacted secret shape, duplicate, and oversized output" do
    assert {:error, :logs_container_mismatch} =
             RemoteLogs.read(deployment(),
               execute: emitting([%{snapshot() | "container_name" => "unmanaged"}]),
               executable: "/nix/store/cli/bin/nixploy"
             )

    assert {:error, :logs_secret_shape_detected} =
             RemoteLogs.read(deployment(),
               execute:
                 emitting([%{snapshot() | "content" => "TOKEN=plaintext", "line_count" => 1}]),
               executable: "/nix/store/cli/bin/nixploy"
             )

    assert {:error, :duplicate_logs_observation} =
             RemoteLogs.read(deployment(),
               execute: emitting([snapshot(), snapshot()]),
               executable: "/nix/store/cli/bin/nixploy"
             )

    assert {:error, :logs_output_too_large} =
             RemoteLogs.read(deployment(),
               execute: fn _command, _opts ->
                 {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: true}}
               end,
               executable: "/nix/store/cli/bin/nixploy"
             )
  end

  defp emitting(snapshots) do
    fn _command, opts ->
      Enum.each(snapshots, &opts[:on_line].(Jason.encode!(&1)))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end
  end

  defp snapshot do
    %{
      "schema" => "nixploy.logs/v1",
      "operation_id" => deployment().id,
      "resource_key" => deployment().resource_prefix,
      "container_name" => deployment().container_name,
      "content" => "ready\nTOKEN=[REDACTED]",
      "line_count" => 2,
      "truncated" => false,
      "observed_at" => "2026-08-05T00:00:00Z"
    }
  end

  defp deployment do
    %NativeDeployment{
      id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      target: "production",
      resource_prefix: "nixploy-fixture-bab0990cab-production",
      container_name: "nixploy-fixture-bab0990cab-production-green",
      deployment_input: %DeploymentInput{
        store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source",
        source_revision: String.duplicate("b", 40),
        source_repository: "fixture/repository",
        configuration_digest: String.duplicate("c", 64)
      }
    }
  end
end
