defmodule Nixploy.RuntimeTest do
  use Nixploy.DataCase, async: false
  use Oban.Testing, repo: Nixploy.Repo

  alias Nixploy.Deployments.{DeploymentInput, NativeDeployment}
  alias Nixploy.{Fixtures, NativeDeployments, Repo, Runtime}

  setup do
    previous = Application.get_env(:nixploy, :managed_applications)

    Application.put_env(:nixploy, :managed_applications, %{
      "fixture" => %{
        "project" => "fixture",
        "target" => "production",
        "repository" => "/home/jonas/coding/fixture",
        "repository_identity" => "owner/fixture"
      }
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nixploy, :managed_applications, previous),
        else: Application.delete_env(:nixploy, :managed_applications)
    end)

    :ok
  end

  test "inventory contains only host-allowlisted applications and latest persisted worker state" do
    deployment = deployment_fixture()

    assert {:ok, _event} =
             NativeDeployments.record_remote_observation(deployment.id, %{
               "target_identity" => %{
                 "host" => "203.0.113.10",
                 "user" => "deploy",
                 "port" => 22
               },
               "container_verified" => true,
               "container_id" => "container-123",
               "container_name" => "nixploy-fixture-bab0990cab-production-blue",
               "container_state" => "running",
               "image_reference" => "fixture:latest",
               "image_id" => "sha256:image",
               "revision" => String.duplicate("b", 40),
               "active_slot" => "blue",
               "ingress_available" => true,
               "active_port" => 18_080,
               "expected_port" => 18_080,
               "caddy_route_id" => "nixploy-route-nixploy-fixture-bab0990cab-production",
               "caddy_upstream" => "127.0.0.1:18080",
               "target_local_health" => %{
                 "healthy" => true,
                 "endpoint" => "http://127.0.0.1:18080/health"
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
               "healthy" => true,
               "converged" => true
             })

    assert {:ok, inventory} = Runtime.inventory()
    assert [%Runtime.Workload{} = workload] = inventory.workloads
    assert workload.id == "fixture"
    assert workload.managed?
    assert workload.connection == "nixploy-fixture-bab0990cab-production"
    assert workload.connection_state == "connected"
    assert workload.state == "running"
    assert workload.status == "converged"
    assert workload.container_id == "container-123"
    assert workload.revision == String.duplicate("b", 40)
    assert workload.target_host == "203.0.113.10"
    assert workload.caddy_upstream == "127.0.0.1:18080"
    refute workload.stale?

    assert {:ok, details} = Runtime.workload_details("fixture")
    assert details.resource_key == workload.resource_key
    assert details.cpu_percent == "1.2%"
    assert details.memory_usage == "12MiB / 1GiB"
    assert details.pids == "7"
    assert details.target_local_health["healthy"]
    assert details.public_health["status_code"] == 200
    assert details.observation_error == nil
  end

  test "allowlisted application without a deployment is explicit unavailable state" do
    assert {:ok, inventory} = Runtime.inventory()

    assert [%Runtime.Workload{state: "unavailable", status: "no deployment", stale?: true}] =
             inventory.workloads
  end

  test "ephemeral logs are request-generation fenced and exposed without history" do
    deployment = deployment_fixture()
    operator = Fixtures.operator_fixture()

    assert {:ok, snapshot, job} = Runtime.request_logs("fixture", operator)
    assert job.args[:native_deployment_id] == deployment.id
    assert snapshot.status == :pending

    assert {:error, :stale_request} =
             Runtime.complete_logs("fixture", Ecto.UUID.generate(), %{
               content: "wrong generation",
               line_count: 1,
               truncated: false
             })

    assert {:ok, completed} =
             Runtime.complete_logs("fixture", snapshot.request_id, %{
               content: "ready\nTOKEN=[REDACTED]",
               line_count: 2,
               truncated: false
             })

    assert completed.status == :available
    assert {:ok, details} = Runtime.workload_details("fixture")
    assert details.logs == "ready\nTOKEN=[REDACTED]"
    assert details.log_status == :available
    assert details.log_line_count == 2
  end

  defp deployment_fixture do
    operator = Fixtures.operator_fixture()
    now = DateTime.utc_now()

    input =
      %DeploymentInput{
        input_kind: :git_main,
        registration_channel: :operator,
        application_key: "fixture",
        source_repository: "owner/fixture",
        source_ref: "refs/heads/main",
        source_revision: String.duplicate("b", 40),
        repository_subdirectory: ".",
        store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source",
        nar_hash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        selected_target: "production",
        derived_snapshot: %{
          "project" => "fixture",
          "target" => %{
            "image_output" => "fixtureImage",
            "domain" => "fixture.invalid",
            "health_path" => "/health",
            "slots" => %{"blue" => 18_080, "green" => 18_081},
            "run" => %{"pre_start" => []},
            "credential_references" => %{},
            "tasks" => %{}
          }
        },
        configuration_digest: String.duplicate("c", 64),
        state: :staged,
        requested_by_operator_id: operator.id,
        requested_at: now,
        resolved_at: now,
        started_at: now,
        finished_at: now
      }
      |> Repo.insert!()

    %NativeDeployment{
      deployment_input_id: input.id,
      requested_by_operator_id: operator.id,
      project: "fixture",
      target: "production",
      operation_kind: :deploy,
      state: :succeeded,
      current_stage: :succeeded,
      resource_prefix: "nixploy-fixture-bab0990cab-production",
      selected_slot: "blue",
      selected_port: 18_080,
      image_reference: "fixture:latest",
      image_id: "sha256:image",
      container_name: "nixploy-fixture-bab0990cab-production-blue",
      container_id: "container-123",
      verified_upstream: "127.0.0.1:18080",
      started_at: now,
      finished_at: now
    }
    |> Repo.insert!()
  end
end
