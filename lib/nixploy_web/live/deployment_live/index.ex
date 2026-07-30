defmodule NixployWeb.DeploymentLive.Index do
  use NixployWeb, :live_view

  alias Nixploy.{Applications, Audit}
  alias Nixploy.Applications.{Repository, Service}
  alias Nixploy.Deployments
  alias Nixploy.Deployments.Deployment
  alias Nixploy.Fleet
  alias Nixploy.Fleet.Target
  alias Nixploy.{LocalHost, Notifications, Operations}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Notifications.subscribe()

    socket =
      socket
      |> assign(:page_title, "Local host")
      |> assign(:local_inventory, nil)
      |> assign(:local_inventory_error, nil)
      |> assign(:local_inventory_status, :loading)
      |> assign(:selected_workload, nil)
      |> assign(:workload_details, nil)
      |> assign(:workload_details_error, nil)
      |> assign(:workload_details_status, :idle)
      |> load_dashboard()
      |> assign_forms()

    if connected?(socket), do: send(self(), :load_local_inventory)

    {:ok, socket}
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

  def handle_event("refresh_local_inventory", _params, socket) do
    send(self(), :load_local_inventory)

    {:noreply,
     assign(socket,
       local_inventory_status: :loading,
       local_inventory_error: nil,
       selected_workload: nil,
       workload_details: nil,
       workload_details_error: nil,
       workload_details_status: :idle
     )}
  end

  def handle_event("inspect_local_workload", %{"id" => workload_id}, socket) do
    case inventory_workload(socket.assigns.local_inventory, workload_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That workload is no longer in the inventory")}

      workload ->
        send(self(), {:load_workload_details, workload.id})

        {:noreply,
         assign(socket,
           selected_workload: workload,
           workload_details: nil,
           workload_details_error: nil,
           workload_details_status: :loading
         )}
    end
  end

  def handle_event("refresh_local_workload", _params, socket) do
    case socket.assigns.selected_workload do
      nil ->
        {:noreply, socket}

      workload ->
        send(self(), {:load_workload_details, workload.id})

        {:noreply,
         assign(socket,
           workload_details_error: nil,
           workload_details_status: :loading
         )}
    end
  end

  def handle_event("close_local_workload", _params, socket) do
    {:noreply,
     assign(socket,
       selected_workload: nil,
       workload_details: nil,
       workload_details_error: nil,
       workload_details_status: :idle
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
  def handle_info(:load_local_inventory, socket) do
    # TODO(tracer): Move local observation to a supervised worker before adding
    # polling or multi-host inventory; this first slice keeps one bounded probe
    # observable directly from the LiveView.
    case local_inventory_probe().() do
      {:ok, inventory} ->
        {:noreply,
         assign(socket,
           local_inventory: inventory,
           local_inventory_status: :available,
           local_inventory_error: nil
         )}

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

  def handle_info({:deployment_changed, _deployment_id}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:service_status_changed, _service_id}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:service_logs_changed, _service_id}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  defp local_inventory_probe do
    Application.get_env(:nixploy, :local_inventory_probe, &LocalHost.inventory/0)
  end

  defp local_workload_probe do
    Application.get_env(:nixploy, :local_workload_probe, &LocalHost.workload_details/1)
  end

  defp inventory_workload(nil, _workload_id), do: nil

  defp inventory_workload(inventory, workload_id) do
    Enum.find(inventory.workloads, &(&1.id == workload_id))
  end

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
  end

  defp load_dashboard(socket) do
    repositories = Applications.list_repositories()
    targets = Fleet.list_targets()
    services = Applications.list_services()
    deployments = Deployments.list_deployments()
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
      repositories: repositories,
      targets: targets,
      services: services,
      deployments: deployments,
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

  defp service_label(service), do: "#{service.name} on #{service.target.name}"

  def edit_repository_form(repository),
    do: repository |> Applications.change_repository() |> to_form(as: :repository)

  def edit_target_form(target), do: target |> Fleet.change_target() |> to_form(as: :target)

  def edit_service_form(service),
    do: service |> Applications.change_service() |> to_form(as: :service)

  def terminal?(deployment), do: Deployment.terminal?(deployment)

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
