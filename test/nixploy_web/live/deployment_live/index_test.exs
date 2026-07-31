defmodule NixployWeb.DeploymentLive.IndexTest do
  use NixployWeb.ConnCase
  use Oban.Testing, repo: Nixploy.Repo

  import Phoenix.LiveViewTest

  alias Nixploy.Deployments
  alias Nixploy.Deployments.{LocalStoreInput, NativeWorker, SimulatedWorker}
  alias Nixploy.LocalHost
  alias Nixploy.Fixtures
  alias Nixploy.Operations.{LogWorker, StatusWorker}

  defmodule NativeExecutorStub do
    def deploy(_deployment, opts) do
      stage = Keyword.fetch!(opts, :stage)
      :ok = stage.(:preparing, "Preparing", %{})

      :ok =
        stage.(:building, "Building", %{
          resource_prefix: "nixploy-mobile-fixture",
          selected_slot: "blue",
          selected_port: 8080
        })

      :ok = stage.(:loading, "Loading", %{image_store_path: "/nix/store/image"})

      :ok =
        stage.(:preparing_slot, "Preparing slot", %{
          image_reference: "fixture:latest",
          image_id: "sha256:image"
        })

      :ok = stage.(:starting, "Starting", %{container_name: "nixploy-mobile-fixture-blue"})
      :ok = stage.(:health_checking, "Healthy", %{container_id: "container-id"})
      :ok = stage.(:switching, "Switching", %{})
      :ok = stage.(:verifying, "Verifying", %{})
      stage.(:succeeded, "Succeeded", %{verified_upstream: "127.0.0.1:8080"})
    end
  end

  defmodule NativeGreenExecutorStub do
    def deploy(_deployment, opts) do
      stage = Keyword.fetch!(opts, :stage)
      :ok = stage.(:preparing, "Preparing", %{})

      :ok =
        stage.(:building, "Building", %{
          resource_prefix: "nixploy-mobile-fixture",
          previous_upstream: "127.0.0.1:8080",
          selected_slot: "green",
          selected_port: 8081
        })

      :ok = stage.(:loading, "Loading", %{image_store_path: "/nix/store/image"})

      :ok =
        stage.(:preparing_slot, "Preparing slot", %{
          image_reference: "fixture:latest",
          image_id: "sha256:image"
        })

      :ok = stage.(:starting, "Starting", %{container_name: "nixploy-mobile-fixture-green"})
      :ok = stage.(:health_checking, "Healthy", %{container_id: "green-container-id"})
      :ok = stage.(:switching, "Switching", %{})
      :ok = stage.(:verifying, "Verifying", %{})
      stage.(:succeeded, "Succeeded", %{verified_upstream: "127.0.0.1:8081"})
    end
  end

  setup %{conn: conn} do
    previous_probe = Application.get_env(:nixploy, :local_inventory_probe)
    previous_workload_probe = Application.get_env(:nixploy, :local_workload_probe)
    previous_health_probe = Application.get_env(:nixploy, :local_health_probe)
    previous_store_probe = Application.get_env(:nixploy, :local_store_input_probe)
    previous_native_executor = Application.get_env(:nixploy, :native_deployment_executor)

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

    store_source = %LocalStoreInput.Source{
      store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-mobile-fixture-source",
      nar_hash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      project: "mobile-fixture",
      targets: %{
        "production" => %{
          "name" => "production",
          "image_output" => "packages.x86_64-linux.container-image-with-a-long-name",
          "domain" => "fixture.example.test",
          "health_path" => "/ready",
          "slots" => %{"blue" => 8080, "green" => 8081}
        }
      }
    }

    Application.put_env(:nixploy, :local_store_input_probe, fn _path, _opts ->
      {:ok, store_source}
    end)

    Application.put_env(:nixploy, :native_deployment_executor, NativeExecutorStub)

    on_exit(fn ->
      restore_env(:local_inventory_probe, previous_probe)
      restore_env(:local_workload_probe, previous_workload_probe)
      restore_env(:local_health_probe, previous_health_probe)
      restore_env(:local_store_input_probe, previous_store_probe)
      restore_env(:native_deployment_executor, previous_native_executor)
    end)

    operator = Fixtures.operator_fixture()
    {:ok, conn: log_in_operator(conn, operator), operator: operator}
  end

  test "discovers the local Podman host without manual registration", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#local-host-inventory", "nixploy-vps")
    assert has_element?(view, "#operations-overview", "Current runtime state")
    assert has_element?(view, "#local-workload-abcdef123456", "jomat")
    assert has_element?(view, "nav[aria-label='Primary navigation']", "Workloads")
    assert has_element?(view, "#mobile-nav-open[aria-expanded='false']")
    assert has_element?(view, "#mobile-nav[aria-hidden='true']", "Operations")
    assert has_element?(view, "#mobile-nav-close")
    refute html =~ "&quot;to&quot;:&quot;body&quot;"
    refute has_element?(view, "#local-workload-123456abcdef")
    refute has_element?(view, "#local-store-inspect-form")
    refute has_element?(view, "#native-operations-page")
  end

  test "opens local workload details and bounded logs without registration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workloads")

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
    {:ok, view, _html} = live(conn, ~p"/workloads")

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

    {:ok, view, _html} = live(conn, ~p"/workloads")

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

    {:ok, view, _html} = live(conn, ~p"/workloads")

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

  test "inspects and stages an immutable source through the authenticated UI", %{
    conn: conn,
    operator: operator
  } do
    jobs_before = Nixploy.Repo.aggregate(Oban.Job, :count)
    {:ok, view, _html} = live(conn, ~p"/deployment-inputs")

    view
    |> form("#local-store-inspect-form", %{
      "local_store" => %{
        "store_path" => "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-mobile-fixture-source"
      }
    })
    |> render_submit()

    assert has_element?(view, "#local-store-candidate", "mobile-fixture")
    assert has_element?(view, "#local-store-candidate", "sha256-AAAA")
    assert has_element?(view, "#local-store-target-preview", "container-image-with-a-long-name")
    assert has_element?(view, "#local-store-target-preview", "fixture.example.test")
    assert has_element?(view, "#local-store-target-preview", "/ready")
    refute has_element?(view, "#immutable-input-staging input[name*='domain']")
    refute has_element?(view, "#immutable-input-staging input[name*='health']")
    refute has_element?(view, "#immutable-input-staging input[name*='port']")

    view
    |> form("#local-store-stage-form", %{
      "local_store_stage" => %{"selected_target" => "production"}
    })
    |> render_submit()

    [input] = Deployments.list_deployment_inputs()
    assert_redirect(view, ~p"/deployment-inputs/#{input.id}")
    assert input.requested_by_operator_id == operator.id
    assert input.state == :staged
    assert Nixploy.Repo.aggregate(Oban.Job, :count) == jobs_before

    {:ok, detail, html} = live(conn, ~p"/deployment-inputs/#{input.id}")
    assert has_element?(detail, "#deployment-input-store-path", "/nix/store/")
    assert has_element?(detail, "#deployment-input-nar-hash", "sha256-AAAA")
    assert has_element?(detail, "#deployment-input-project", "mobile-fixture")
    assert has_element?(detail, "#deployment-input-target", "production")
    assert has_element?(detail, "#deployment-input-image", "container-image-with-a-long-name")
    assert has_element?(detail, "#deployment-input-domain", "fixture.example.test")
    assert has_element?(detail, "#deployment-input-health", "/ready")
    assert has_element?(detail, "#deployment-input-actor", operator.email)
    assert has_element?(detail, "#staging-no-mutation", "did not enqueue a deployment")
    assert html =~ "overflow-x-hidden"
    assert html =~ "break-all"
    assert html =~ "min-w-0"
  end

  test "keeps native operation history on its own utility route", %{
    conn: conn,
    operator: operator
  } do
    assert {:ok, input} =
             Deployments.stage_local_store(
               %{
                 store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-mobile-fixture-source",
                 selected_target: "production"
               },
               operator: operator
             )

    {:ok, deployment, _job} = Nixploy.NativeDeployments.enqueue(input.id, operator: operator)
    {:ok, view, html} = live(conn, ~p"/native-deployments")

    assert has_element?(view, "#native-operations-page", "Native operations")
    assert has_element?(view, "#native-deployment-#{deployment.id}", "mobile-fixture")
    assert has_element?(view, "a[aria-current='page'][href='/native-deployments']")
    refute has_element?(view, "#local-host-inventory")
    refute has_element?(view, "#immutable-input-staging")
    assert html =~ "min-w-0"
  end

  test "queues and follows native deployment progress from the immutable input page", %{
    conn: conn,
    operator: operator
  } do
    assert {:ok, input} =
             Deployments.stage_local_store(
               %{
                 store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-mobile-fixture-source",
                 selected_target: "production"
               },
               operator: operator
             )

    {:ok, input_view, _html} = live(conn, ~p"/deployment-inputs/#{input.id}")

    input_view
    |> element("#deploy-native-input")
    |> render_click()

    [deployment] = Nixploy.NativeDeployments.list_for_input(input.id)
    assert_redirect(input_view, ~p"/native-deployments/#{deployment.id}")
    assert_enqueued(worker: NativeWorker, args: %{native_deployment_id: deployment.id})

    {:ok, operation_view, queued_html} = live(conn, ~p"/native-deployments/#{deployment.id}")
    assert queued_html =~ "overflow-x-hidden"
    assert has_element?(operation_view, "#native-current-stage", "queued")
    assert has_element?(operation_view, "#native-deployment-events", "Native deployment queued")

    assert :ok = perform_job(NativeWorker, %{native_deployment_id: deployment.id})

    assert has_element?(operation_view, "#native-current-stage", "succeeded")
    assert has_element?(operation_view, "#native-verified-upstream", "127.0.0.1:8080")
    assert has_element?(operation_view, "#native-deployment-events", "Succeeded")
    assert render(operation_view) =~ "break-all"
  end

  test "confirms and queues an exact rollback from a verified operation", %{
    conn: conn,
    operator: operator
  } do
    assert {:ok, input} =
             Deployments.stage_local_store(
               %{
                 store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-mobile-fixture-source",
                 selected_target: "production"
               },
               operator: operator
             )

    {:ok, blue, _job} = Nixploy.NativeDeployments.enqueue(input.id, operator: operator)
    assert :ok = perform_job(NativeWorker, %{native_deployment_id: blue.id})

    Application.put_env(:nixploy, :native_deployment_executor, NativeGreenExecutorStub)
    {:ok, green, _job} = Nixploy.NativeDeployments.enqueue(input.id, operator: operator)
    assert :ok = perform_job(NativeWorker, %{native_deployment_id: green.id})

    {:ok, view, html} = live(conn, ~p"/native-deployments/#{blue.id}")
    assert html =~ "overflow-x-hidden"
    assert has_element?(view, "#rollback-native-deployment", "Roll back to this result")

    view
    |> element("#rollback-native-deployment")
    |> render_click()

    [rollback | _] = Nixploy.NativeDeployments.list_for_input(input.id)
    assert rollback.operation_kind == :rollback
    assert rollback.rollback_of_id == blue.id
    assert rollback.expected_image_id == "sha256:image"
    assert rollback.expected_slot == "blue"
    assert_redirect(view, ~p"/native-deployments/#{rollback.id}")

    {:ok, rollback_view, rollback_html} =
      live(conn, ~p"/native-deployments/#{rollback.id}")

    assert has_element?(rollback_view, "#native-rollback-identity", blue.id)
    assert has_element?(rollback_view, "#native-rollback-identity", "sha256:image")
    assert rollback_html =~ "break-all"
  end

  test "renders immutable source failures without crashing LiveView", %{conn: conn} do
    Application.put_env(:nixploy, :local_store_input_probe, fn _path, _opts ->
      {:error, :path_info_timeout}
    end)

    {:ok, view, _html} = live(conn, ~p"/deployment-inputs")

    view
    |> form("#local-store-inspect-form", %{
      "local_store" => %{"store_path" => "/nix/store/missing-source"}
    })
    |> render_submit()

    assert has_element?(view, "#local-store-error", "timed out after 30 seconds")
    assert has_element?(view, "#inputs-page", "Deployment inputs")
    assert has_element?(view, "#local-store-inspect-form")
  end

  test "requires authentication for immutable input detail URLs", %{} do
    operator = Fixtures.operator_fixture()

    assert {:ok, input} =
             Deployments.stage_local_store(
               %{
                 store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-mobile-fixture-source",
                 selected_target: "production"
               },
               operator: operator
             )

    unauthenticated_conn = Phoenix.ConnTest.build_conn()

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(unauthenticated_conn, ~p"/deployment-inputs/#{input.id}")
  end

  test "queues a worker-owned service status refresh", %{conn: conn} do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, view, _html} = live(conn, ~p"/compatibility")

    assert has_element?(view, "#service-status-#{service.id}", "not observed")

    view
    |> element("#refresh-status-#{service.id}")
    |> render_click()

    assert_enqueued(worker: StatusWorker, args: %{service_id: service.id})
    assert has_element?(view, "#service-status-#{service.id}", "pending")
  end

  test "queues a worker-owned active-container log snapshot", %{conn: conn} do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    {:ok, view, _html} = live(conn, ~p"/compatibility")

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

    {:ok, view, _html} = live(conn, ~p"/compatibility")

    assert has_element?(view, "#service-logs-#{service.id}", "Application started")
    assert has_element?(view, "#service-status-#{service.id}", "green")
    assert has_element?(view, "#service-status-#{service.id}", "1 lines")
  end

  test "queues and streams a simulated deployment to completion", %{conn: conn} do
    service = Fixtures.service_fixture()
    {:ok, view, _html} = live(conn, ~p"/compatibility")

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

    {:ok, view, _html} = live(conn, ~p"/compatibility")

    assert has_element?(view, "#deployment-#{deployment.id}", "aaaaaaaaaaaa")
    assert has_element?(view, "#deployment-#{deployment.id}", "Podman connection failed")
  end

  test "requests cancellation from the dashboard", %{conn: conn} do
    deployment = Fixtures.deployment_fixture()
    {:ok, view, _html} = live(conn, ~p"/compatibility")

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
