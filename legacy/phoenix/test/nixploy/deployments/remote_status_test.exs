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
      "project" => "fixture",
      "target" => "production",
      "connection" => deployment().resource_prefix,
      "target_identity" => %{"host" => "203.0.113.10", "user" => "deploy", "port" => 22},
      "container_verified" => true,
      "container_id" => "container-id",
      "container_name" => deployment().container_name,
      "container_state" => "running",
      "container_status" => "Up 1 minute",
      "image_reference" => deployment().image_reference,
      "image_id" => deployment().image_id,
      "revision" => deployment().deployment_input.source_revision,
      "deployed_at" => "2026-08-05T00:00:00Z",
      "ingress_available" => true,
      "active_slot" => "green",
      "active_port" => 8081,
      "expected_port" => 8081,
      "caddy_route_id" => "nixploy-route-#{deployment().resource_prefix}",
      "caddy_proxy_id" => "nixploy-proxy-#{deployment().resource_prefix}",
      "caddy_upstream" => "127.0.0.1:8081",
      "target_local_health" => %{
        "healthy" => true,
        "endpoint" => "http://127.0.0.1:8081/health"
      },
      "public_health" => %{"healthy" => true, "status_code" => 200, "error" => nil},
      "metrics" => %{
        "cpu_percent" => "1.2%",
        "memory_usage" => "12MiB / 1GiB",
        "memory_percent" => "1.2%",
        "pids" => "7",
        "network_io" => "1kB / 2kB",
        "block_io" => "3kB / 4kB"
      },
      "host_metrics" => %{
        "hostname" => "production",
        "architecture" => "amd64",
        "os" => "linux",
        "kernel" => "6.18.38",
        "cpu_count" => 2,
        "distribution" => "nixos",
        "distribution_version" => "26.05",
        "memory_free_bytes" => 1_000_000_000,
        "memory_total_bytes" => 4_000_000_000,
        "swap_free_bytes" => 0,
        "swap_total_bytes" => 0,
        "uptime" => "19d 17h",
        "rootless" => true,
        "containers_total" => 3,
        "containers_running" => 3,
        "containers_stopped" => 0,
        "images_total" => 68,
        "storage_driver" => "overlay",
        "storage_total_bytes" => 80_000_000_000,
        "storage_used_bytes" => 30_000_000_000,
        "podman_version" => "5.8.2"
      },
      "observed_at" => "2026-08-05T00:00:00Z",
      "healthy" => true,
      "converged" => true
    }
  end

  defp deployment do
    %NativeDeployment{
      id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      project: "fixture",
      target: "production",
      resource_prefix: "nixploy-fixture-bab0990cab-production",
      container_name: "nixploy-fixture-bab0990cab-production-green",
      image_reference: "fixture:latest",
      image_id: "sha256:" <> String.duplicate("a", 64),
      container_id: "container-id",
      selected_slot: "green",
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
