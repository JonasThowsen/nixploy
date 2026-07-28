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

    Application.put_env(:nixploy, :local_inventory_probe, fn -> {:ok, inventory} end)

    on_exit(fn ->
      if previous_probe do
        Application.put_env(:nixploy, :local_inventory_probe, previous_probe)
      else
        Application.delete_env(:nixploy, :local_inventory_probe)
      end
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
end
