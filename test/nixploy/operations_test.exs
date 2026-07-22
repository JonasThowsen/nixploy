defmodule Nixploy.OperationsTest do
  use Nixploy.DataCase, async: true
  use Oban.Testing, repo: Nixploy.Repo

  alias Nixploy.Fixtures
  alias Nixploy.Operations
  alias Nixploy.Operations.{LogWorker, StatusWorker}

  test "persists and enqueues a status refresh request" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})

    assert {:ok, observation, job} = Operations.request_status_refresh(service.id)

    assert observation.status == :pending
    assert observation.request_id
    assert observation.requested_at
    assert job.worker == inspect(StatusWorker)
    assert_enqueued(worker: StatusWorker, args: %{service_id: service.id})
  end

  test "persists and enqueues a bounded log snapshot request" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})

    assert {:ok, snapshot, job} = Operations.request_log_snapshot(service.id)

    assert snapshot.status == :pending
    assert snapshot.request_id
    assert snapshot.requested_at
    assert job.worker == inspect(LogWorker)
    assert Operations.get_service_observation(service.id).status == :pending
    assert_enqueued(worker: LogWorker, args: %{service_id: service.id})
  end

  test "persists an available log snapshot" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, requested, _job} = Operations.request_log_snapshot(service.id)

    assert {:ok, snapshot} =
             Operations.complete_log_snapshot(service.id, requested.request_id, %{
               target_identity: "nixploy-app-123-production",
               slot: "green",
               container_name: "nixploy-app-123-production-green",
               content: "first line\nsecond line",
               line_count: 2,
               truncated: false
             })

    assert snapshot.status == :available
    assert snapshot.slot == "green"
    assert snapshot.line_count == 2
    assert snapshot.content == "first line\nsecond line"
    assert snapshot.fetched_at
  end

  test "persists an available observation" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, requested, _job} = Operations.request_status_refresh(service.id)

    assert {:ok, observation} =
             Operations.complete_status_refresh(service.id, requested.request_id, %{
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

  test "rejects stale status completion after a newer request" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, first, _job} = Operations.request_status_refresh(service.id)
    {:ok, second, _job} = Operations.request_status_refresh(service.id)

    attrs = %{
      target_identity: "nixploy-app-production",
      active_slot: "green",
      active_container: "nixploy-app-production-green"
    }

    assert first.request_id != second.request_id

    assert {:error, :stale_request} =
             Operations.complete_status_refresh(service.id, first.request_id, attrs)

    assert Operations.get_service_observation(service.id).request_id == second.request_id
    assert Operations.get_service_observation(service.id).status == :pending
  end

  test "persists probe failures" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, requested, _job} = Operations.request_status_refresh(service.id)

    assert {:ok, observation} =
             Operations.fail_status_refresh(
               service.id,
               requested.request_id,
               {:caddy_route_not_found, service.domain}
             )

    assert observation.status == :failed

    assert (observation.failure["message"] || observation.failure[:message]) =~
             "caddy_route_not_found"
  end
end
