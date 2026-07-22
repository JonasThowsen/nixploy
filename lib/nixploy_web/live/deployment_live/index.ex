defmodule NixployWeb.DeploymentLive.Index do
  use NixployWeb, :live_view

  alias Nixploy.{Applications, Audit}
  alias Nixploy.Applications.{Repository, Service}
  alias Nixploy.Deployments
  alias Nixploy.Deployments.Deployment
  alias Nixploy.Fleet
  alias Nixploy.Fleet.Target
  alias Nixploy.{Notifications, Operations}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Notifications.subscribe()

    socket =
      socket
      |> assign(:page_title, "Deployments")
      |> load_dashboard()
      |> assign_forms()

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
  def handle_info({:deployment_changed, _deployment_id}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:service_status_changed, _service_id}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:service_logs_changed, _service_id}, socket) do
    {:noreply, load_dashboard(socket)}
  end

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
