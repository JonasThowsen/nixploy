defmodule NixployWeb.DeploymentLive.IndexTest do
  use NixployWeb.ConnCase
  use Oban.Testing, repo: Nixploy.Repo

  import Phoenix.LiveViewTest

  alias Nixploy.Deployments
  alias Nixploy.Deployments.SimulatedWorker
  alias Nixploy.LocalHost
  alias Nixploy.Fixtures
  alias Nixploy.Operations.{LogWorker, StatusWorker}

  setup %{conn: conn} do
    previous_probe = Application.get_env(:nixploy, :local_inventory_probe)
    previous_workload_probe = Application.get_env(:nixploy, :local_workload_probe)
    previous_health_probe = Application.get_env(:nixploy, :local_health_probe)

    inventory = %LocalHost.Inventory{
      hostname: "nixploy-vps",
      runtime_user: "nixploy",
      observed_at: ~U[2026-07-27 12:00:00Z],
      workloads: [
        %LocalHost.Workload{
          id: "abcdef123456",
          name: "nixploy-jomat-production-green",
          image: "localhost/jomat:latest",
          state: "running",
          status: "Up 2 hours",
          project: "jomat",
          target: "production",
          revision: "55ef9e674e5d",
          repository: "https://github.com/JonasThowsen/jomat",
          slot: "green",
          managed?: true
        },
        %LocalHost.Workload{
          id: "123456abcdef",
          name: "postgres",
          image: "docker.io/postgres:17",
          state: "running",
          status: "Up 1 day"
        }
      ]
    }

    details = %LocalHost.WorkloadDetails{
      id: "abcdef123456",
      name: "nixploy-jomat-production-green",
      image: "localhost/jomat:latest",
      image_id: "sha256:jomat-image-id",
      state: "running",
      status: "running",
      health: "healthy",
      created_at: ~U[2026-07-27 11:00:00Z],
      started_at: ~U[2026-07-27 12:00:00Z],
      project: "jomat",
      target: "production",
      revision: "55ef9e674e5d",
      repository: "https://github.com/JonasThowsen/jomat",
      deployed_at: "2026-07-27T12:00:00Z",
      slot: "green",
      published_ports: ["127.0.0.1:8081 → 4000/tcp"],
      logs: "Application started\nServing requests",
      log_line_count: 2,
      observed_at: ~U[2026-07-27 12:05:00Z],
      managed?: true
    }

    health_observation = %LocalHost.HealthObservation{
      container_id: "abcdef123456",
      container_name: "nixploy-jomat-production-green",
      container_state: "running",
      status: :healthy,
      endpoint: "http://127.0.0.1:4003/health",
      status_code: 200,
      observed_at: ~U[2026-07-27 12:06:00Z]
    }

    Application.put_env(:nixploy, :local_inventory_probe, fn -> {:ok, inventory} end)
    Application.put_env(:nixploy, :local_workload_probe, fn _id -> {:ok, details} end)

    Application.put_env(:nixploy, :local_health_probe, fn _id ->
      {:ok, health_observation}
    end)

    on_exit(fn ->
      restore_env(:local_inventory_probe, previous_probe)
      restore_env(:local_workload_probe, previous_workload_probe)
      restore_env(:local_health_probe, previous_health_probe)
    end)

    operator = Fixtures.operator_fixture()
    {:ok, conn: log_in_operator(conn, operator), operator: operator}
  end

  test "discovers the local Podman host without manual registration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#local-host-inventory", "nixploy-vps")
    assert has_element?(view, "#local-workload-abcdef123456", "jomat")
    assert has_element?(view, "#local-workload-abcdef123456", "55ef9e674e5d")
    assert has_element?(view, "#local-workload-123456abcdef", "unmanaged")
    refute has_element?(view, "#repository-form")
    refute has_element?(view, "#target-form")
    refute has_element?(view, "#service-form")
    refute has_element?(view, "#deployment-form")
    assert has_element?(view, "#empty-deployments")
  end

  test "opens local workload details and bounded logs without registration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#inspect-workload-abcdef123456")
    |> render_click()

    assert has_element?(view, "#local-workload-details", "nixploy managed")
    assert has_element?(view, "#local-workload-details", "sha256:jomat-image-id")
    assert has_element?(view, "#local-workload-details", "healthy")
    assert has_element?(view, "#local-workload-details", "127.0.0.1:8081 → 4000/tcp")
    assert has_element?(view, "#local-workload-logs", "Application started")
    assert has_element?(view, "#local-workload-details", "2 lines")
  end

  test "probes a selected managed workload and renders a timestamped observation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#inspect-workload-abcdef123456")
    |> render_click()

    view
    |> element("#probe-local-health")
    |> render_click()

    assert has_element?(view, "#local-health-observation", "running")
    assert has_element?(view, "#local-health-observation", "healthy")
    assert has_element?(view, "#local-health-observation", "HTTP 200")
    assert has_element?(view, "#local-health-observation", "http://127.0.0.1:4003/health")
    assert has_element?(view, "#local-health-observation", "2026-07-27 12:06:00 UTC")
  end

  test "renders local health probe failures without crashing", %{conn: conn} do
    Application.put_env(:nixploy, :local_health_probe, fn _id ->
      {:error, :unmanaged_workload}
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#inspect-workload-abcdef123456")
    |> render_click()

    view
    |> element("#probe-local-health")
    |> render_click()

    assert has_element?(view, "#local-health-error", "positively identified")
    assert has_element?(view, "#local-workload-details", "running")
  end

  test "renders workload inspect and log timeout failures without crashing", %{conn: conn} do
    Application.put_env(:nixploy, :local_workload_probe, fn _id ->
      {:error, {:podman_inspect_failed, :timeout}}
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#inspect-workload-abcdef123456")
    |> render_click()

    assert has_element?(view, "#local-workload-details-error", "timed out after 15 seconds")

    details = %LocalHost.WorkloadDetails{
      id: "abcdef123456",
      name: "nixploy-jomat-production-green",
      state: "running",
      logs_error: {:podman_logs_failed, :timeout},
      observed_at: ~U[2026-07-27 12:05:00Z],
      managed?: true
    }

    Application.put_env(:nixploy, :local_workload_probe, fn _id -> {:ok, details} end)

    view
    |> element("#refresh-local-workload")
    |> render_click()

    assert has_element?(view, "#local-workload-logs-error", "timed out after 15 seconds")
    assert has_element?(view, "#local-workload-details", "running")
  end

  test "refreshes local inventory and renders probe failures", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Application.put_env(:nixploy, :local_inventory_probe, fn ->
      {:error, {:podman_failed, 125, "Podman socket unavailable"}}
    end)

    view
    |> element("#refresh-local-inventory")
    |> render_click()

    assert has_element?(view, "#local-inventory-error", "Podman socket unavailable")
  end

  test "queues a worker-owned service status refresh", %{conn: conn} do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#service-status-#{service.id}", "not observed")

    view
    |> element("#refresh-status-#{service.id}")
    |> render_click()

    assert_enqueued(worker: StatusWorker, args: %{service_id: service.id})
    assert has_element?(view, "#service-status-#{service.id}", "pending")
  end

  test "queues a worker-owned active-container log snapshot", %{conn: conn} do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#service-status-#{service.id}", "No log snapshot")

    view
    |> element("#fetch-logs-#{service.id}")
    |> render_click()

    assert_enqueued(worker: LogWorker, args: %{service_id: service.id})
    assert has_element?(view, "#service-status-#{service.id}", "pending")
  end

  test "renders a persisted active-container log snapshot", %{conn: conn} do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, requested, _job} = Nixploy.Operations.request_log_snapshot(service.id)

    {:ok, _snapshot} =
      Nixploy.Operations.complete_log_snapshot(service.id, requested.request_id, %{
        target_identity: "nixploy-app-123-production",
        slot: "green",
        container_name: "nixploy-app-123-production-green",
        content: "Application started",
        line_count: 1,
        truncated: false
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#service-logs-#{service.id}", "Application started")
    assert has_element?(view, "#service-status-#{service.id}", "green")
    assert has_element?(view, "#service-status-#{service.id}", "1 lines")
  end

  test "queues and streams a simulated deployment to completion", %{conn: conn} do
    service = Fixtures.service_fixture()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#deployment-form", %{
      "deployment" => %{"service_id" => service.id, "requested_ref" => "main"}
    })
    |> render_submit()

    [deployment] = Deployments.list_deployments()
    assert_enqueued(worker: SimulatedWorker, args: %{deployment_id: deployment.id})
    assert has_element?(view, "#deployment-#{deployment.id}", "queued")

    assert :ok = perform_job(SimulatedWorker, %{deployment_id: deployment.id})

    assert has_element?(view, "#deployment-#{deployment.id}", "succeeded")
    assert render(view) =~ "Deployment succeeded"
  end

  test "shows the resolved revision and deployment failure", %{conn: conn} do
    deployment = Fixtures.deployment_fixture()
    commit = String.duplicate("a", 40)

    {:ok, _, _} = Deployments.transition(deployment.id, :preparing, "Preparing")

    {:ok, _, _} =
      Deployments.transition(deployment.id, :building, "Resolved revision", %{
        resolved_commit: commit
      })

    {:ok, _, _} =
      Deployments.transition(deployment.id, :failed, "Deployment failed", %{
        failure: %{message: "Podman connection failed"}
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#deployment-#{deployment.id}", "aaaaaaaaaaaa")
    assert has_element?(view, "#deployment-#{deployment.id}", "Podman connection failed")
  end

  test "requests cancellation from the dashboard", %{conn: conn} do
    deployment = Fixtures.deployment_fixture()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#cancel-#{deployment.id}")
    |> render_click()

    assert Deployments.cancellation_requested?(deployment.id)
    assert render(view) =~ "cancelling"

    assert :ok = perform_job(SimulatedWorker, %{deployment_id: deployment.id})
    assert has_element?(view, "#deployment-#{deployment.id}", "cancelled")
  end

  defp restore_env(key, nil), do: Application.delete_env(:nixploy, key)
  defp restore_env(key, value), do: Application.put_env(:nixploy, key, value)
end
