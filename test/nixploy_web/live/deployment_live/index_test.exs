defmodule NixployWeb.DeploymentLive.IndexTest do
  use NixployWeb.ConnCase
  use Oban.Testing, repo: Nixploy.Repo

  import Phoenix.LiveViewTest

  alias Nixploy.Deployments
  alias Nixploy.Deployments.SimulatedWorker
  alias Nixploy.Fixtures
  alias Nixploy.Operations.{LogWorker, StatusWorker}

  setup %{conn: conn} do
    operator = Fixtures.operator_fixture()
    {:ok, conn: log_in_operator(conn, operator), operator: operator}
  end

  test "renders the deployment dashboard", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Deployment control plane"
    assert has_element?(view, "#repository-form")
    assert has_element?(view, "#target-form")
    assert has_element?(view, "#service-form")
    assert has_element?(view, "#deployment-form")
    assert has_element?(view, "#service-statuses")
    assert has_element?(view, "#empty-deployments")
  end

  test "renders validation errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#repository-form", %{
      "repository" => %{"name" => "", "url" => "", "default_ref" => ""}
    })
    |> render_submit()

    assert has_element?(view, "#repository-form p.text-error", "can't be blank")
  end

  test "creates repository, target, and service records", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#repository-form", %{
      "repository" => %{
        "name" => "demo",
        "url" => "https://example.com/demo.git",
        "default_ref" => "main"
      }
    })
    |> render_submit()

    view
    |> form("#target-form", %{
      "target" => %{
        "name" => "production",
        "host" => "prod.example.com",
        "ssh_user" => "deploy",
        "ssh_port" => "22"
      }
    })
    |> render_submit()

    [repository] = Nixploy.Applications.list_repositories()
    [target] = Nixploy.Fleet.list_targets()

    view
    |> form("#service-form", %{
      "service" => %{
        "name" => "web",
        "repository_id" => repository.id,
        "target_id" => target.id,
        "flake_output" => "docker",
        "domain" => "demo.example.com",
        "health_path" => "/health"
      }
    })
    |> render_submit()

    assert [service] = Nixploy.Applications.list_services()
    assert service.name == "web"
    assert render(view) =~ "1"
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
