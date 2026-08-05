defmodule NixployWeb.DeploymentLive.NativeShow do
  use NixployWeb, :live_view

  alias Nixploy.Deployments.NativeDeployment
  alias Nixploy.{NativeDeployments, Notifications, Tasks}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Notifications.subscribe(id)

    {:ok,
     socket
     |> assign(:page_title, "Deployment")
     |> assign(:native_deployment_id, id)
     |> load()}
  end

  @impl true
  def handle_event("rollback_native_deployment", _params, socket) do
    case NativeDeployments.request_rollback(socket.assigns.deployment.id,
           operator: socket.assigns.current_operator
         ) do
      {:ok, rollback, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rollback started")
         |> push_navigate(to: ~p"/deployments/#{rollback.id}")}

      {:error, {:rollback_already_active, _id}} ->
        {:noreply, put_flash(socket, :error, "This exact verified result is already active")}

      {:error, {:rollback_target_not_succeeded, _state}} ->
        {:noreply,
         put_flash(socket, :error, "Only a succeeded native operation can be rolled back")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue rollback")}
    end
  end

  @impl true
  def handle_event(
        "run_task",
        %{"task_name" => task_name, "confirmed_name" => confirmed_name},
        socket
      ) do
    case Tasks.enqueue(
           socket.assigns.deployment.id,
           task_name,
           confirmed_name,
           socket.assigns.current_operator
         ) do
      {:ok, _operation, _job} ->
        {:noreply, socket |> put_flash(:info, "Operational task queued") |> load()}

      {:error, :task_confirmation_mismatch} ->
        {:noreply, put_flash(socket, :error, "Type the exact task name to confirm")}

      {:error, :task_not_declared} ->
        {:noreply, put_flash(socket, :error, "That task is not declared by this release")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue operational task")}
    end
  end

  @impl true
  def handle_event("cancel_native_deployment", _params, socket) do
    case NativeDeployments.request_cancellation(socket.assigns.deployment.id,
           operator: socket.assigns.current_operator
         ) do
      {:ok, _deployment, _event} ->
        {:noreply, socket |> put_flash(:info, "Cancellation requested") |> load()}

      {:error, {:terminal, state}} ->
        {:noreply, put_flash(socket, :error, "Deployment is already #{state}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not request cancellation")}
    end
  end

  @impl true
  def handle_info({:deployment_changed, id}, socket) when id == socket.assigns.deployment.id,
    do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    deployment = NativeDeployments.get_deployment!(socket.assigns.native_deployment_id)

    assign(socket,
      deployment: deployment,
      events: NativeDeployments.list_events(deployment.id),
      rollback_status: NativeDeployments.rollback_status(deployment),
      task_operations: Tasks.list_for_deployment(deployment.id)
    )
  end

  def terminal?(deployment), do: NativeDeployment.terminal?(deployment)
  def state_class(:succeeded), do: "badge-success"
  def state_class(:failed), do: "badge-error"
  def state_class(:cancelled), do: "badge-warning"
  def state_class(_state), do: "badge-info"

  def stage_label(:queued), do: "Waiting for worker"
  def stage_label(:preparing), do: "Verifying release"
  def stage_label(:building), do: "Building image"
  def stage_label(:loading), do: "Loading image"
  def stage_label(:installing_credentials), do: "Applying credentials"
  def stage_label(:preparing_slot), do: "Preparing inactive slot"
  def stage_label(:pre_starting), do: "Running preparation"
  def stage_label(:starting), do: "Starting candidate"
  def stage_label(:health_checking), do: "Checking health"
  def stage_label(:switching), do: "Switching traffic"
  def stage_label(:verifying), do: "Verifying production"
  def stage_label(:succeeded), do: "Deployment complete"
  def stage_label(:failed), do: "Deployment failed"
  def stage_label(:cancelled), do: "Deployment cancelled"

  def stage_label(stage),
    do: stage |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def format_time(nil), do: "—"
  def format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
