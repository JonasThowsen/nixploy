defmodule Nixploy.Deployments.RemotePlanTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.{DeploymentInput, NativeDeployment, RemotePlan}
  alias Nixploy.Execution.Result

  test "accepts one bounded fresh plan matching the immutable release and canonical resource" do
    parent = self()

    execute = fn command, opts ->
      send(parent, {:command, command})
      opts[:on_line].("bounded diagnostic")
      opts[:on_line].(Jason.encode!(plan()))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end

    assert {:ok, observed} =
             RemotePlan.read(deployment(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy",
               workspace: "/tmp/private",
               env: %{"HOME" => "/tmp/private"}
             )

    assert observed["candidate_port"] == 18_080
    assert_receive {:command, command}
    assert command.args |> Enum.take(2) == ["plan", "--target"]
    assert command.cd == "/tmp/private"
    assert command.max_output_bytes == 65_536
  end

  test "fails closed when the packaged plan changes the canonical resource" do
    execute = fn _command, opts ->
      opts[:on_line].(Jason.encode!(%{plan() | "resource_key" => "nixploy-wrong"}))
      {:ok, %Result{exit_status: 0, output_tail: "", output_truncated?: false}}
    end

    assert {:error, :plan_resource_mismatch} =
             RemotePlan.read(deployment(),
               execute: execute,
               executable: "/nix/store/cli/bin/nixploy"
             )
  end

  defp plan do
    resource = "nixploy-fixture-bab0990cab-production"

    %{
      "schema" => "nixploy.plan/v1",
      "operation_id" => deployment().id,
      "resource_key" => resource,
      "project" => "fixture",
      "target" => "production",
      "connection" => resource,
      "target_identity" => %{"host" => "203.0.113.10", "user" => "deploy", "port" => 22},
      "image_output" => "fixtureImage",
      "active_slot" => nil,
      "active_port" => nil,
      "candidate_slot" => "blue",
      "candidate_port" => 18_080,
      "current_container" => nil,
      "caddy_route_id" => "nixploy-route-#{resource}",
      "caddy_proxy_id" => "nixploy-proxy-#{resource}",
      "domain" => "fixture.invalid",
      "health_endpoint" => "http://127.0.0.1:18080/health",
      "pre_start_count" => 1,
      "credential_count" => 1,
      "task_names" => ["migrate"],
      "intended_effects" => ~w(
        build_image
        install_credentials
        load_remote_image
        run_fixed_pre_start
        start_inactive_slot
        check_target_local_health
        switch_exact_caddy_route
        independent_readback
      )
    }
  end

  defp deployment do
    %NativeDeployment{
      id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      project: "fixture",
      target: "production",
      resource_prefix: "nixploy-fixture-bab0990cab-production",
      deployment_input: %DeploymentInput{
        store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source",
        source_revision: String.duplicate("b", 40),
        source_repository: "fixture/repository",
        configuration_digest: String.duplicate("c", 64),
        derived_snapshot: %{
          "project" => "fixture",
          "target" => %{
            "image_output" => "fixtureImage",
            "domain" => "fixture.invalid",
            "health_path" => "/health",
            "slots" => %{"blue" => 18_080, "green" => 18_081},
            "run" => %{"pre_start" => [["/app/migrate"]]},
            "credential_references" => %{"app" => "/nix/store/secret"},
            "tasks" => %{"migrate" => %{"command" => ["/app/migrate"]}}
          }
        }
      }
    }
  end
end
