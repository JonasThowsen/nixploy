defmodule NixployWeb.DeploymentLive.NativeShow do
  use NixployWeb, :live_view

  alias Nixploy.Deployments.NativeDeployment
  alias Nixploy.{NativeDeployments, Notifications}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Notifications.subscribe(id)

    {:ok,
     socket
     |> assign(:page_title, "Native deployment")
     |> assign(:native_deployment_id, id)
     |> load()}
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
      events: NativeDeployments.list_events(deployment.id)
    )
  end

  def terminal?(deployment), do: NativeDeployment.terminal?(deployment)
  def state_class(:succeeded), do: "badge-success"
  def state_class(:failed), do: "badge-error"
  def state_class(:cancelled), do: "badge-warning"
  def state_class(_state), do: "badge-info"
  def format_time(nil), do: "—"
  def format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
