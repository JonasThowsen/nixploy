defmodule NixployWeb.DeploymentLive.Index do
  use NixployWeb, :live_view

  alias Nixploy.{Deployments, ManagedApplications}

  alias Nixploy.{
    ControlPlaneHealth,
    NativeDeployments,
    Notifications,
    Runtime,
    RuntimeMode,
    WorkerHeartbeat
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
      |> load_dashboard()

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

  def handle_event("refresh_machine_health", _params, socket) do
    case runtime_refresh().(socket.assigns.current_operator) do
      {:ok, %{queued: queued}} when queued > 0 ->
        {:noreply,
         socket
         |> put_flash(:info, "Remote target refresh queued")
         |> assign(machine_health_status: :loading, machine_health_error: nil)}

      {:ok, _result} ->
        {:noreply, put_flash(socket, :error, "No deployed application target is available")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not refresh remote target: #{inspect(reason)}")}
    end
  end

  def handle_event("refresh_local_inventory", _params, socket) do
    _ = runtime_refresh().(socket.assigns.current_operator)
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
        {:noreply,
         socket
         |> select_workload(workload)
         |> push_patch(to: ~p"/applications?application=#{workload.id}")}
    end
  end

  def handle_event("refresh_local_workload", _params, socket) do
    case socket.assigns.selected_workload do
      nil ->
        {:noreply, socket}

      workload ->
        case runtime_workload_refresh().(workload.id, socket.assigns.current_operator) do
          {:ok, _job} ->
            send(self(), {:load_workload_details, workload.id})

            {:noreply,
             socket
             |> put_flash(:info, "Remote application refresh queued")
             |> assign(
               workload_details_error: nil,
               workload_details_status: :loading,
               local_health_error: nil,
               local_health_status: :loading
             )}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not refresh remote application: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("probe_local_health", _params, socket) do
    case socket.assigns.selected_workload do
      %{id: workload_id, managed?: true, state: state} when state != "unavailable" ->
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

  def handle_event("fetch_runtime_logs", _params, socket) do
    case socket.assigns.selected_workload do
      %{id: application_key} ->
        case Runtime.request_logs(application_key, socket.assigns.current_operator) do
          {:ok, _snapshot, _job} ->
            {:noreply,
             socket
             |> put_flash(:info, "Bounded remote log snapshot queued")
             |> assign(:workload_details_status, :loading)}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not queue remote logs: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Choose a managed application first")}
    end
  end

  @impl true
  def handle_info(:load_machine_health, socket) do
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
    send(self(), :load_local_inventory)
    if socket.assigns.live_action == :machine, do: send(self(), :load_machine_health)

    if socket.assigns.selected_workload do
      send(self(), {:load_workload_details, socket.assigns.selected_workload.id})
    end

    {:noreply, load_dashboard(socket)}
  end

  defp machine_health_probe do
    Application.get_env(:nixploy, :machine_health_probe, &Runtime.target_machine/0)
  end

  defp local_inventory_probe do
    Application.get_env(:nixploy, :local_inventory_probe, &Runtime.inventory/0)
  end

  defp local_workload_probe do
    Application.get_env(:nixploy, :local_workload_probe, &Runtime.workload_details/1)
  end

  defp local_health_probe do
    Application.get_env(:nixploy, :local_health_probe, &Runtime.observe_health/1)
  end

  defp runtime_refresh do
    Application.get_env(:nixploy, :runtime_refresh, &Runtime.request_refresh_all/1)
  end

  defp runtime_workload_refresh do
    Application.get_env(:nixploy, :runtime_workload_refresh, &Runtime.request_refresh/2)
  end

  defp select_workload(socket, workload) do
    send(self(), {:load_workload_details, workload.id})
    health_available? = workload.managed? and workload.state != "unavailable"
    if health_available?, do: send(self(), {:probe_local_health, workload.id})

    assign(socket,
      selected_workload: workload,
      workload_details: nil,
      workload_details_error: nil,
      workload_details_status: :loading,
      local_health_observation: nil,
      local_health_error: nil,
      local_health_status: if(health_available?, do: :loading, else: :idle)
    )
  end

  defp inventory_workload(nil, _workload_id), do: nil
  defp inventory_workload(_inventory, nil), do: nil

  defp inventory_workload(inventory, workload_id) do
    Enum.find(inventory.workloads, &(&1.id == workload_id))
  end

  defp machine_health_error(:remote_observation_unavailable),
    do: "No remote target observation is available yet. Refresh the application target."

  defp machine_health_error(_reason), do: "Remote target diagnostics are temporarily unavailable"

  defp local_inventory_error(:managed_application_not_found),
    do: "The managed application is no longer allowlisted"

  defp local_inventory_error({:executable_not_found, executable}),
    do: "#{executable} is not available to the nixploy worker"

  defp local_inventory_error({:podman_failed, _status, output}) when output != "",
    do: String.trim(output)

  defp local_inventory_error(:podman_inventory_too_large),
    do: "Podman returned more than the bounded 1 MiB inventory limit"

  defp local_inventory_error(reason), do: inspect(reason)

  defp local_workload_error(:managed_application_not_found),
    do: "The managed application is no longer allowlisted"

  defp local_workload_error({:podman_inspect_failed, :timeout}),
    do: "Remote Podman inspection timed out after 15 seconds"

  defp local_workload_error({:podman_inspect_failed, status, output})
       when is_integer(status) and is_binary(output) and output != "",
       do: "Podman inspect exited with status #{status}: #{String.trim(output)}"

  defp local_workload_error(:podman_inspect_too_large),
    do: "Podman inspect exceeded the bounded 1 MiB output limit"

  defp local_workload_error(reason), do: inspect(reason)

  def workload_logs_error(:expired),
    do: "The ephemeral log snapshot expired; request a fresh bounded snapshot"

  def workload_logs_error(reason) when is_binary(reason), do: reason

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

  defp load_dashboard(socket) do
    assign(socket,
      managed_applications: ManagedApplications.list(),
      deployment_inputs: Deployments.list_deployment_inputs(),
      native_deployments: NativeDeployments.list_deployments(),
      worker_heartbeat: WorkerHeartbeat.latest(),
      control_plane_health: ControlPlaneHealth.snapshot()
    )
  end

  defp normalize_selection(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      selected -> selected
    end
  end

  defp normalize_selection(_value), do: nil

  def nav_path(:overview), do: "/"
  def nav_path(:machine), do: "/machine"
  def nav_path(:applications), do: "/applications"
  def nav_path(:releases), do: "/releases"
  def nav_path(:deployments), do: "/deployments"

  defp page_title(:overview), do: "Overview"
  defp page_title(:machine), do: "Machine health"
  defp page_title(:applications), do: "Applications"
  defp page_title(:releases), do: "Releases"
  defp page_title(:deployments), do: "Deployments"

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

  def application_releases(inputs, inventory, _deployments) do
    projects = if inventory, do: managed_projects(inventory), else: MapSet.new()

    Enum.filter(inputs, fn input ->
      input.state == :staged and
        (input.input_kind == :git_main or
           MapSet.member?(projects, input.derived_snapshot["project"]))
    end)
  end

  def application_inputs(inputs, application_key) do
    Enum.filter(inputs, &input_for_application?(&1, application_key))
  end

  def latest_application_input(inputs, application_key) do
    matches = Enum.filter(inputs, &input_for_application?(&1, application_key))
    Enum.find(matches, &(&1.state == :staged)) || List.first(matches)
  end

  defp input_for_application?(input, application_key) do
    case ManagedApplications.fetch(application_key) do
      {:ok, application} ->
        input.application_key == application_key or
          (input.registration_channel == :ci and
             input.source_repository == application.repository_identity and
             input.selected_target == application.target and
             input.derived_snapshot["project"] == application.project)

      {:error, _reason} ->
        false
    end
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
      snapshot.storage_percent >= 95 or snapshot.memory_percent >= 95 -> :critical
      snapshot.storage_percent >= 85 or snapshot.memory_percent >= 85 -> :warning
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
end
