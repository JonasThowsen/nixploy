defmodule Nixploy.OperationsTest do
  use Nixploy.DataCase, async: true
  use Oban.Testing, repo: Nixploy.Repo

  alias Nixploy.Fixtures
  alias Nixploy.Operations
  alias Nixploy.Operations.StatusWorker

  test "persists and enqueues a status refresh request" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})

    assert {:ok, observation, job} = Operations.request_status_refresh(service.id)

    assert observation.status == :pending
    assert observation.requested_at
    assert job.worker == inspect(StatusWorker)
    assert_enqueued(worker: StatusWorker, args: %{service_id: service.id})
  end

  test "persists an available observation" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, _, _job} = Operations.request_status_refresh(service.id)

    assert {:ok, observation} =
             Operations.complete_status_refresh(service.id, %{
               target_identity: "nixploy-app-123-production",
               active_slot: "green",
               inactive_slot: "blue",
               active_container: "nixploy-app-123-production-green",
               active_container_state: "running",
               inactive_container: "nixploy-app-123-production-blue",
               inactive_container_state: "absent",
               image: "localhost/app:latest",
               git_commit: "abcdef123456",
               deployed_at: ~U[2026-07-22 13:26:59.000000Z],
               caddy_route: "nixploy-route-nixploy-app-123-production",
               upstream: "127.0.0.1:8081",
               health_url: "https://app.example.com/health",
               health_status: 200
             })

    assert observation.status == :available
    assert observation.active_slot == "green"
    assert observation.health_status == 200
    assert observation.refreshed_at
  end

  test "persists probe failures" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, _, _job} = Operations.request_status_refresh(service.id)

    assert {:ok, observation} =
             Operations.fail_status_refresh(service.id, {:caddy_route_not_found, service.domain})

    assert observation.status == :failed

    assert (observation.failure["message"] || observation.failure[:message]) =~
             "caddy_route_not_found"
  end
end
