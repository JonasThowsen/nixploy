defmodule Nixploy.Deployments.RemoteStatusTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.{DeploymentInput, NativeDeployment, RemoteStatus}
  alias Nixploy.Execution.Result

  test "parses one exact operation-bound status observation from packaged CLI diagnostics" do
    execute = fn command, opts ->
      send(self(), {:command, command})
      opts[:on_line].("human diagnostic")
      opts[:on_line].(Jason.encode!(observation()))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end

    assert {:ok, observed} =
             RemoteStatus.observe(deployment(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy"
             )

    assert observed["converged"]
    assert_receive {:command, command}
    assert command.args |> Enum.take(2) == ["status", "--target"]
    assert ["--expected-port", "8081"] = Enum.take(command.args, -2)
    assert command.max_output_bytes == 65_536
  end

  test "rejects mismatched, duplicate, missing, and oversized observations" do
    mismatched = put_in(observation(), ["operation_id"], Ecto.UUID.generate())

    assert {:error, :status_operation_mismatch} =
             RemoteStatus.observe(deployment(),
               execute: emitting([mismatched]),
               executable: "/nix/store/cli/bin/nixploy"
             )

    assert {:error, :duplicate_status_observation} =
             RemoteStatus.observe(deployment(),
               execute: emitting([observation(), observation()]),
               executable: "/nix/store/cli/bin/nixploy"
             )

    assert {:error, :status_observation_missing} =
             RemoteStatus.observe(deployment(),
               execute: emitting([]),
               executable: "/nix/store/cli/bin/nixploy"
             )

    assert {:error, :status_output_too_large} =
             RemoteStatus.observe(deployment(),
               execute: fn _command, _opts ->
                 {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: true}}
               end,
               executable: "/nix/store/cli/bin/nixploy"
             )
  end

  defp emitting(observations) do
    fn _command, opts ->
      Enum.each(observations, &opts[:on_line].(Jason.encode!(&1)))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end
  end

  defp observation do
    %{
      "schema" => "nixploy.status/v1",
      "operation_id" => deployment().id,
      "resource_key" => deployment().resource_prefix,
      "container_verified" => true,
      "container_id" => "container-id",
      "image_id" => deployment().image_id,
      "ingress_available" => true,
      "active_port" => 8081,
      "expected_port" => 8081,
      "healthy" => true,
      "converged" => true
    }
  end

  defp deployment do
    %NativeDeployment{
      id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      target: "production",
      resource_prefix: "nixploy-fixture-bab0990cab-production",
      container_name: "nixploy-fixture-bab0990cab-production-green",
      image_reference: "fixture:latest",
      image_id: "sha256:" <> String.duplicate("a", 64),
      selected_port: 8081,
      deployment_input: %DeploymentInput{
        store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source",
        source_revision: String.duplicate("b", 40),
        source_repository: "fixture/repository",
        configuration_digest: String.duplicate("c", 64)
      }
    }
  end
end
