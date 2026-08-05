defmodule NixployWeb.DeploymentLive.Index do
  use NixployWeb, :live_view

  alias Nixploy.{Applications, Audit, ManagedApplications}
  alias Nixploy.Applications.{Repository, Service}
  alias Nixploy.Deployments
  alias Nixploy.Deployments.{Deployment, DeploymentInput, LocalStoreInput}
  alias Nixploy.Fleet
  alias Nixploy.Fleet.Target

  alias Nixploy.{
    LocalHost,
    MachineHealth,
    NativeDeployments,
    Notifications,
    Operations,
    RuntimeMode
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Notifications.subscribe()

    socket =
      socket
      |> assign(:page_title, page_title(socket.assigns.live_action))
      |> assign(:runtime_mode, RuntimeMode.current())
      |> assign(:local_inventory, nil)
      |> assign(:local_inventory_error, nil)
      |> assign(:local_inventory_status, :loading)
      |> assign(:machine_health, nil)
      |> assign(:machine_health_error, nil)
      |> assign(:machine_health_status, :idle)
      |> assign(:selected_workload, nil)
      |> assign(:requested_workload_id, nil)
      |> assign(:workload_details, nil)
      |> assign(:workload_details_error, nil)
      |> assign(:workload_details_status, :idle)
      |> assign(:local_health_observation, nil)
      |> assign(:local_health_error, nil)
      |> assign(:local_health_status, :idle)
      |> assign(:local_store_candidate, nil)
      |> assign(:local_store_selected_target, nil)
      |> assign(:local_store_status, :idle)
      |> assign(:local_store_error, nil)
      |> load_dashboard()
      |> assign_forms()

    if connected?(socket) do
      send(self(), :load_local_inventory)
      if socket.assigns.live_action == :machine, do: send(self(), :load_machine_health)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested_id = normalize_selection(params["application"])
    socket = assign(socket, :requested_workload_id, requested_id)

    case inventory_workload(socket.assigns.local_inventory, requested_id) do
      nil -> {:noreply, socket}
      workload -> {:noreply, select_workload(socket, workload)}
    end
  end

  @impl true
  def handle_event("save_repository", %{"repository" => params}, socket) do
    case Applications.create_repository(params, operator: socket.assigns.current_operator) do
      {:ok, _repository} ->
        {:noreply,
         socket
         |> put_flash(:info, "Repository added")
         |> assign(:repository_form, repository_form())
         |> load_dashboard()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :repository_form, changeset |> Map.put(:action, :insert) |> to_form())}
    end
  end

  def handle_event("save_target", %{"target" => params}, socket) do
    case Fleet.create_target(params, operator: socket.assigns.current_operator) do
      {:ok, _target} ->
        {:noreply,
         socket
         |> put_flash(:info, "Target added")
         |> assign(:target_form, target_form())
         |> load_dashboard()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :target_form, changeset |> Map.put(:action, :insert) |> to_form())}
    end
  end

  def handle_event("save_service", %{"service" => params}, socket) do
    case Applications.create_service(params, operator: socket.assigns.current_operator) do
      {:ok, _service} ->
        {:noreply,
         socket
         |> put_flash(:info, "Service attached")
         |> assign(:service_form, service_form())
         |> load_dashboard()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :service_form, changeset |> Map.put(:action, :insert) |> to_form())}
    end
  end

  def handle_event("update_repository", %{"_id" => id, "repository" => params}, socket) do
    repository = Applications.get_repository!(id)

    case Applications.update_repository(repository, params,
           operator: socket.assigns.current_operator
         ) do
      {:ok, _repository} ->
        {:noreply, socket |> put_flash(:info, "Repository updated") |> load_dashboard()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error(changeset))}
    end
  end

  def handle_event("update_target", %{"_id" => id, "target" => params}, socket) do
    target = Fleet.get_target!(id)

    case Fleet.update_target(target, params, operator: socket.assigns.current_operator) do
      {:ok, _target} ->
        {:noreply, socket |> put_flash(:info, "Target updated") |> load_dashboard()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error(changeset))}
    end
  end

  def handle_event("update_service", %{"_id" => id, "service" => params}, socket) do
    service = Applications.get_service!(id)

    case Applications.update_service(service, params, operator: socket.assigns.current_operator) do
      {:ok, _service} ->
        {:noreply, socket |> put_flash(:info, "Service updated") |> load_dashboard()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error(changeset))}
    end
  end

  def handle_event("enqueue_deployment", %{"deployment" => params}, socket) do
    case Deployments.enqueue_deployment(params, operator: socket.assigns.current_operator) do
      {:ok, _deployment, _event, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deployment queued")
         |> assign(:deployment_form, deployment_form(socket.assigns.services))
         |> load_dashboard()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :deployment_form, changeset |> Map.put(:action, :insert) |> to_form())}
    end
  end

  def handle_event("select_deployment_service", payload, socket) do
    params = payload["deployment"]

    requested_ref =
      if payload["_target"] == ["deployment", "service_id"] do
        case Enum.find(socket.assigns.services, &(&1.id == params["service_id"])) do
          nil -> params["requested_ref"]
          service -> service.repository.default_ref
        end
      else
        params["requested_ref"]
      end

    form =
      %Deployment{}
      |> Deployments.change_deployment(Map.put(params, "requested_ref", requested_ref))
      |> to_form(as: :deployment)

    {:noreply, assign(socket, :deployment_form, form)}
  end

  def handle_event("prepare_main", %{"application" => application_key}, socket) do
    case Deployments.prepare_main(application_key, operator: socket.assigns.current_operator) do
      {:ok, input, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Main preparation queued")
         |> push_navigate(to: ~p"/releases/#{input.id}")}

      {:error, :managed_application_not_found} ->
        {:noreply, put_flash(socket, :error, "That managed application is unavailable")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not prepare main: #{inspect(reason)}")}
    end
  end

  def handle_event("inspect_local_store", %{"local_store" => params}, socket) do
    store_path = params["store_path"]

    case Deployments.inspect_local_store(store_path) do
      {:ok, source} ->
        target_names = source.targets |> Map.keys() |> Enum.sort()
        selected_target = if length(target_names) == 1, do: List.first(target_names)

        {:noreply,
         assign(socket,
           local_store_candidate: source,
           local_store_selected_target: selected_target,
           local_store_stage_form: local_store_stage_form(selected_target),
           local_store_form: local_store_form(source.store_path),
           local_store_status: :verified,
           local_store_error: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           local_store_candidate: nil,
           local_store_selected_target: nil,
           local_store_stage_form: local_store_stage_form(),
           local_store_status: :failed,
           local_store_error: LocalStoreInput.error_message(reason)
         )}
    end
  end

  def handle_event("select_local_store_target", %{"local_store_stage" => params}, socket) do
    selected_target = normalize_selection(params["selected_target"])

    {:noreply,
     assign(socket,
       local_store_selected_target: selected_target,
       local_store_stage_form: local_store_stage_form(selected_target),
       local_store_error: nil
     )}
  end

  def handle_event("stage_local_store", %{"local_store_stage" => params}, socket) do
    case socket.assigns.local_store_candidate do
      nil ->
        {:noreply,
         assign(socket,
           local_store_status: :failed,
           local_store_error: "Inspect an immutable store source before staging it."
         )}

      source ->
        attrs = %{
          store_path: source.store_path,
          expected_nar_hash: source.nar_hash,
          selected_target: params["selected_target"]
        }

        case Deployments.stage_local_store(attrs, operator: socket.assigns.current_operator) do
          {:ok, input} ->
            {:noreply,
             socket
             |> put_flash(:info, "Release registered")
             |> push_navigate(to: ~p"/releases/#{input.id}")}

          {:error, %DeploymentInput{} = input} ->
            {:noreply,
             socket
             |> put_flash(:error, input.failure["message"])
             |> push_navigate(to: ~p"/releases/#{input.id}")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket,
               local_store_status: :failed,
               local_store_error: changeset_error(changeset)
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               local_store_status: :failed,
               local_store_error: LocalStoreInput.error_message(reason)
             )}
        end
    end
  end

  def handle_event("refresh_machine_health", _params, socket) do
    send(self(), :load_machine_health)

    {:noreply,
     assign(socket,
       machine_health_status: :loading,
       machine_health_error: nil
     )}
  end

  def handle_event("refresh_local_inventory", _params, socket) do
    send(self(), :load_local_inventory)

    {:noreply,
     assign(socket,
       local_inventory_status: :loading,
       local_inventory_error: nil,
       selected_workload: nil,
       workload_details: nil,
       workload_details_error: nil,
       workload_details_status: :idle,
       local_health_observation: nil,
       local_health_error: nil,
       local_health_status: :idle
     )}
  end

  def handle_event("inspect_local_workload", %{"id" => workload_id}, socket) do
    case inventory_workload(socket.assigns.local_inventory, workload_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That workload is no longer in the inventory")}

      workload ->
        {:noreply, select_workload(socket, workload)}
    end
  end

  def handle_event("refresh_local_workload", _params, socket) do
    case socket.assigns.selected_workload do
      nil ->
        {:noreply, socket}

      workload ->
        send(self(), {:load_workload_details, workload.id})
        if workload.managed?, do: send(self(), {:probe_local_health, workload.id})

        {:noreply,
         assign(socket,
           workload_details_error: nil,
           workload_details_status: :loading,
           local_health_error: nil,
           local_health_status: if(workload.managed?, do: :loading, else: :idle)
         )}
    end
  end

  def handle_event("probe_local_health", _params, socket) do
    case socket.assigns.selected_workload do
      %{id: workload_id, managed?: true} ->
        send(self(), {:probe_local_health, workload_id})

        {:noreply,
         assign(socket,
           local_health_error: nil,
           local_health_status: :loading
         )}

      _unavailable ->
        {:noreply, put_flash(socket, :error, "Only a discovered managed workload can be probed")}
    end
  end

  def handle_event("close_local_workload", _params, socket) do
    {:noreply,
     assign(socket,
       selected_workload: nil,
       workload_details: nil,
       workload_details_error: nil,
       workload_details_status: :idle,
       local_health_observation: nil,
       local_health_error: nil,
       local_health_status: :idle
     )}
  end

  def handle_event("fetch_service_logs", %{"id" => service_id}, socket) do
    case Operations.request_log_snapshot(service_id, operator: socket.assigns.current_operator) do
      {:ok, _snapshot, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Log snapshot queued")
         |> load_dashboard()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue log snapshot")}
    end
  end

  def handle_event("refresh_service_status", %{"id" => service_id}, socket) do
    case Operations.request_status_refresh(service_id, operator: socket.assigns.current_operator) do
      {:ok, _observation, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Status refresh queued")
         |> load_dashboard()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue status refresh")}
    end
  end

  def handle_event("retry_deployment", %{"id" => deployment_id}, socket) do
    case Deployments.retry_deployment(deployment_id, operator: socket.assigns.current_operator) do
      {:ok, _deployment, _event, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Exact revision queued as a new deployment")
         |> load_dashboard()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not redeploy that revision")}
    end
  end

  def handle_event("cancel_deployment", %{"id" => deployment_id}, socket) do
    case Deployments.request_cancellation(deployment_id,
           operator: socket.assigns.current_operator
         ) do
      {:ok, _deployment, _event} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cancellation requested")
         |> load_dashboard()}

      {:error, {:terminal, state}} ->
        {:noreply, put_flash(socket, :error, "Deployment is already #{state}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not request cancellation")}
    end
  end

  @impl true
  def handle_info(:load_machine_health, socket) do
    # TODO(tracer): Move machine sampling to a supervised periodic observer before
    # adding history, charts, alerts, or multiple hosts. This page intentionally
    # shows one bounded sample requested by an authenticated operator.
    case machine_health_probe().() do
      {:ok, snapshot} ->
        {:noreply,
         assign(socket,
           machine_health: snapshot,
           machine_health_status: :available,
           machine_health_error: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           machine_health_status: :failed,
           machine_health_error: machine_health_error(reason)
         )}
    end
  end

  def handle_info(:load_local_inventory, socket) do
    # TODO(tracer): Move local observation to a supervised worker before adding
    # polling or multi-host inventory; this first slice keeps one bounded probe
    # observable directly from the LiveView.
    case local_inventory_probe().() do
      {:ok, inventory} ->
        socket =
          assign(socket,
            local_inventory: inventory,
            local_inventory_status: :available,
            local_inventory_error: nil
          )

        socket =
          case inventory_workload(inventory, socket.assigns.requested_workload_id) do
            nil -> socket
            workload -> select_workload(socket, workload)
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           local_inventory_status: :failed,
           local_inventory_error: local_inventory_error(reason)
         )}
    end
  end

  def handle_info({:load_workload_details, workload_id}, socket) do
    if socket.assigns.selected_workload && socket.assigns.selected_workload.id == workload_id do
      case local_workload_probe().(workload_id) do
        {:ok, details} ->
          {:noreply,
           assign(socket,
             workload_details: details,
             workload_details_status: :available,
             workload_details_error: nil
           )}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             workload_details: nil,
             workload_details_status: :failed,
             workload_details_error: local_workload_error(reason)
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:probe_local_health, workload_id}, socket) do
    if socket.assigns.selected_workload && socket.assigns.selected_workload.id == workload_id do
      case local_health_probe().(workload_id) do
        {:ok, observation} ->
          {:noreply,
           assign(socket,
             local_health_observation: observation,
             local_health_status: observation.status,
             local_health_error: nil
           )}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             local_health_observation: nil,
             local_health_status: :failed,
             local_health_error: local_health_error(reason)
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:deployment_changed, _deployment_id}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:service_status_changed, _service_id}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:service_logs_changed, _service_id}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  defp machine_health_probe do
    Application.get_env(:nixploy, :machine_health_probe, &MachineHealth.snapshot/0)
  end

  defp local_inventory_probe do
    Application.get_env(:nixploy, :local_inventory_probe, &LocalHost.inventory/0)
  end

  defp local_workload_probe do
    Application.get_env(:nixploy, :local_workload_probe, &LocalHost.workload_details/1)
  end

  defp local_health_probe do
    Application.get_env(:nixploy, :local_health_probe, &LocalHost.observe_health/1)
  end

  defp select_workload(socket, workload) do
    send(self(), {:load_workload_details, workload.id})
    if workload.managed?, do: send(self(), {:probe_local_health, workload.id})

    assign(socket,
      selected_workload: workload,
      workload_details: nil,
      workload_details_error: nil,
      workload_details_status: :loading,
      local_health_observation: nil,
      local_health_error: nil,
      local_health_status: if(workload.managed?, do: :loading, else: :idle)
    )
  end

  defp inventory_workload(nil, _workload_id), do: nil
  defp inventory_workload(_inventory, nil), do: nil

  defp inventory_workload(inventory, workload_id) do
    Enum.find(inventory.workloads, &(&1.id == workload_id))
  end

  defp machine_health_error({:disk_usage_failed, :timeout}),
    do: "Disk observation timed out after 10 seconds"

  defp machine_health_error({:disk_usage_failed, _reason}),
    do: "Disk usage is temporarily unavailable"

  defp machine_health_error({:machine_health_read_failed, _path, _reason}),
    do: "Host kernel metrics are temporarily unavailable"

  defp machine_health_error(_reason), do: "Machine health is temporarily unavailable"

  defp local_inventory_error({:executable_not_found, executable}),
    do: "#{executable} is not available to the nixploy service"

  defp local_inventory_error({:podman_failed, _status, output}) when output != "",
    do: String.trim(output)

  defp local_inventory_error(:podman_inventory_too_large),
    do: "Podman returned more than the bounded 1 MiB inventory limit"

  defp local_inventory_error(reason), do: inspect(reason)

  defp local_workload_error({:podman_inspect_failed, :timeout}),
    do: "Podman inspection timed out after 15 seconds"

  defp local_workload_error({:podman_inspect_failed, status, output})
       when is_integer(status) and is_binary(output) and output != "",
       do: "Podman inspect exited with status #{status}: #{String.trim(output)}"

  defp local_workload_error(:podman_inspect_too_large),
    do: "Podman inspect exceeded the bounded 1 MiB output limit"

  defp local_workload_error(reason), do: inspect(reason)

  def workload_logs_error({:podman_logs_failed, :timeout}),
    do: "Podman logs timed out after 15 seconds"

  def workload_logs_error({:podman_logs_failed, status, output})
      when is_integer(status) and is_binary(output),
      do: "Podman logs exited with status #{status}: #{String.trim(output)}"

  def workload_logs_error(reason), do: inspect(reason)

  def workload_metrics_error(:podman_stats_too_large),
    do: "Podman returned more than the bounded 64 KiB metrics limit"

  def workload_metrics_error({:podman_stats_failed, :timeout}),
    do: "Resource metrics timed out after 15 seconds"

  def workload_metrics_error({:podman_stats_failed, status}) when is_integer(status),
    do: "Resource metrics are temporarily unavailable (Podman exited #{status})"

  def workload_metrics_error(_reason), do: "Resource metrics are temporarily unavailable"

  defp local_health_error(:unmanaged_workload),
    do: "Health probes are restricted to workloads positively identified by nixploy labels"

  defp local_health_error(reason), do: inspect(reason)

  def local_health_class(:healthy), do: "badge-success"
  def local_health_class(:unhealthy), do: "badge-error"
  def local_health_class(:failed), do: "badge-warning"
  def local_health_class(_status), do: "badge-ghost"

  def managed_workload_count(nil), do: 0

  def managed_workload_count(inventory) do
    Enum.count(inventory.workloads, & &1.managed?)
  end

  def workload_state_class(state) when state in ["running", "Running"], do: "badge-success"
  def workload_state_class(state) when state in ["paused", "Paused"], do: "badge-warning"
  def workload_state_class(_state), do: "badge-ghost"

  def repository_link?(repository) when is_binary(repository) do
    case URI.new(repository) do
      {:ok, %URI{scheme: scheme}} when scheme in ["http", "https"] -> true
      _other -> false
    end
  end

  def repository_link?(_repository), do: false

  defp assign_forms(socket) do
    socket
    |> assign(:repository_form, repository_form())
    |> assign(:target_form, target_form())
    |> assign(:service_form, service_form())
    |> assign(:deployment_form, deployment_form(socket.assigns.services))
    |> assign(:local_store_form, local_store_form())
    |> assign(:local_store_stage_form, local_store_stage_form())
  end

  defp load_dashboard(socket) do
    repositories = Applications.list_repositories()
    targets = Fleet.list_targets()
    services = Applications.list_services()
    deployments = Deployments.list_deployments()
    deployment_inputs = Deployments.list_deployment_inputs()
    native_deployments = NativeDeployments.list_deployments()
    audit_events = Audit.list_recent_events(50)

    observations_by_service =
      Operations.list_service_observations()
      |> Map.new(&{&1.service_id, &1})

    log_snapshots_by_service =
      Operations.list_service_log_snapshots()
      |> Map.new(&{&1.service_id, &1})

    events_by_deployment =
      Map.new(deployments, fn deployment ->
        {deployment.id, Deployments.list_events(deployment.id)}
      end)

    assign(socket,
      managed_applications: ManagedApplications.list(),
      repositories: repositories,
      targets: targets,
      services: services,
      deployments: deployments,
      deployment_inputs: deployment_inputs,
      native_deployments: native_deployments,
      observations_by_service: observations_by_service,
      log_snapshots_by_service: log_snapshots_by_service,
      events_by_deployment: events_by_deployment,
      audit_events: audit_events,
      repository_options: Enum.map(repositories, &{&1.name, &1.id}),
      target_options: Enum.map(targets, &{&1.name, &1.id}),
      service_options: Enum.map(services, &{service_label(&1), &1.id})
    )
  end

  defp repository_form do
    %Repository{}
    |> Applications.change_repository()
    |> to_form(as: :repository)
  end

  defp target_form do
    %Target{}
    |> Fleet.change_target()
    |> to_form(as: :target)
  end

  defp service_form do
    %Service{}
    |> Applications.change_service()
    |> to_form(as: :service)
  end

  defp deployment_form(services) do
    default_ref =
      case services do
        [service | _rest] -> service.repository.default_ref
        [] -> "main"
      end

    %Deployment{requested_ref: default_ref}
    |> Deployments.change_deployment()
    |> to_form(as: :deployment)
  end

  defp local_store_form(store_path \\ "") do
    to_form(%{"store_path" => store_path}, as: :local_store)
  end

  defp local_store_stage_form(selected_target \\ nil) do
    to_form(%{"selected_target" => selected_target || ""}, as: :local_store_stage)
  end

  defp normalize_selection(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      selected -> selected
    end
  end

  defp normalize_selection(_value), do: nil

  def selected_local_store_target(nil, _selected_target), do: nil

  def selected_local_store_target(source, selected_target) do
    source.targets[selected_target]
  end

  def local_store_target_options(nil), do: []

  def local_store_target_options(source) do
    source.targets
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&{&1, &1})
  end

  def nav_path(:overview), do: "/"
  def nav_path(:machine), do: "/machine"
  def nav_path(:applications), do: "/applications"
  def nav_path(:releases), do: "/releases"
  def nav_path(:deployments), do: "/deployments"
  def nav_path(:compatibility), do: nil

  defp page_title(:overview), do: "Overview"
  defp page_title(:machine), do: "Machine health"
  defp page_title(:applications), do: "Applications"
  defp page_title(:releases), do: "Releases"
  defp page_title(:deployments), do: "Deployments"
  defp page_title(:compatibility), do: "Compatibility operations"

  defp service_label(service), do: "#{service.name} on #{service.target.name}"

  def edit_repository_form(repository),
    do: repository |> Applications.change_repository() |> to_form(as: :repository)

  def edit_target_form(target), do: target |> Fleet.change_target() |> to_form(as: :target)

  def edit_service_form(service),
    do: service |> Applications.change_service() |> to_form(as: :service)

  def terminal?(deployment), do: Deployment.terminal?(deployment)

  def latest_native_deployment(native_deployments, input_id),
    do: Enum.find(native_deployments, &(&1.deployment_input_id == input_id))

  def running_workload_count(nil), do: 0

  def running_workload_count(inventory) do
    Enum.count(inventory.workloads, &(&1.managed? and &1.state in ["running", "Running"]))
  end

  def failed_deployment_count(deployments),
    do: Enum.count(deployments, &(&1.state == :failed))

  def active_deployment_count(deployments),
    do: Enum.count(deployments, &(not Nixploy.Deployments.NativeDeployment.terminal?(&1)))

  # TODO(tracer): Replace runtime-label matching with a durable application ID
  # when Slice 1.5 adopts the first real project. Until then, hiding fixture-only
  # evidence keeps the primary operator lists about applications that exist now;
  # retained evidence remains reachable through its stable compatibility URL.
  def application_deployments(_deployments, nil), do: []

  def application_deployments(deployments, inventory) do
    projects = managed_projects(inventory)
    Enum.filter(deployments, &MapSet.member?(projects, &1.project))
  end

  def application_releases(_inputs, nil, _deployments), do: []

  def application_releases(inputs, inventory, deployments) do
    projects = if inventory, do: managed_projects(inventory), else: MapSet.new()

    latest_states =
      Enum.reduce(deployments, %{}, fn deployment, states ->
        Map.put_new(states, deployment.deployment_input_id, deployment.state)
      end)

    Enum.filter(inputs, fn input ->
      (input.input_kind == :git_main or
         MapSet.member?(projects, input.derived_snapshot["project"])) and
        latest_states[input.id] != :failed
    end)
  end

  def application_inputs(inputs, application_key) do
    Enum.filter(inputs, &(&1.application_key == application_key))
  end

  def latest_application_input(inputs, application_key) do
    Enum.find(inputs, &(&1.application_key == application_key))
  end

  defp managed_projects(inventory) do
    inventory.workloads
    |> Enum.filter(& &1.managed?)
    |> MapSet.new(& &1.project)
  end

  def input_state_class(:staged), do: "badge-success"
  def input_state_class(:failed), do: "badge-error"
  def input_state_class(_state), do: "badge-warning"

  def state_class(:succeeded), do: "badge-success"
  def state_class(:failed), do: "badge-error"
  def state_class(:cancelled), do: "badge-warning"
  def state_class(_state), do: "badge-info"

  def observation_class(:available), do: "badge-success"
  def observation_class(:failed), do: "badge-error"
  def observation_class(:pending), do: "badge-warning"

  def log_snapshot_class(:available), do: "badge-success"
  def log_snapshot_class(:failed), do: "badge-error"
  def log_snapshot_class(:pending), do: "badge-warning"

  def health_class(status) when status in 200..299, do: "badge-success"
  def health_class(nil), do: "badge-ghost"
  def health_class(_status), do: "badge-error"

  def machine_status(nil), do: :unknown

  def machine_status(snapshot) do
    cond do
      snapshot.disk_percent >= 95 or snapshot.memory_percent >= 95 -> :critical
      snapshot.disk_percent >= 85 or snapshot.memory_percent >= 85 -> :warning
      snapshot.cpu_percent >= 90 -> :warning
      snapshot.load_1 > snapshot.cpu_count * 1.5 -> :warning
      true -> :healthy
    end
  end

  def machine_status_class(:healthy), do: "badge-success"
  def machine_status_class(:warning), do: "badge-warning"
  def machine_status_class(:critical), do: "badge-error"
  def machine_status_class(_status), do: "badge-ghost"

  def format_percent(nil), do: "—"
  def format_percent(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1) <> "%"

  def format_bytes(nil), do: "—"

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    units = [{1_099_511_627_776, "TB"}, {1_073_741_824, "GB"}, {1_048_576, "MB"}, {1024, "KB"}]

    case Enum.find(units, fn {size, _unit} -> bytes >= size end) do
      {size, unit} -> :erlang.float_to_binary(bytes / size, decimals: 1) <> " " <> unit
      nil -> "#{bytes} B"
    end
  end

  def format_duration(nil), do: "—"

  def format_duration(seconds) when is_integer(seconds) and seconds >= 0 do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3_600)
    minutes = seconds |> rem(3_600) |> div(60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      true -> "#{minutes}m"
    end
  end

  def short_commit(nil), do: "-"
  def short_commit(commit), do: String.slice(commit, 0, 12)

  def format_time(nil), do: "-"
  def format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    details =
      Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
      |> Enum.map_join(", ", fn {field, messages} ->
        "#{field} #{Enum.join(messages, " and ")}"
      end)

    "Could not update configuration: #{details}"
  end

  defp changeset_error(reason), do: "Could not update configuration: #{inspect(reason)}"
end
