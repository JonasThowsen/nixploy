defmodule NixployWeb.DeploymentLive.Show do
  use NixployWeb, :live_view

  alias Nixploy.{Deployments, NativeDeployments, Notifications}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Notifications.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Release")
     |> assign(:deployment_input_id, id)
     |> load()}
  end

  @impl true
  def handle_event("deploy_native", _params, socket) do
    case NativeDeployments.enqueue(socket.assigns.deployment_input.id,
           operator: socket.assigns.current_operator
         ) do
      {:ok, deployment, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deployment started")
         |> push_navigate(to: ~p"/deployments/#{deployment.id}")}

      {:error, :native_secrets_not_supported} ->
        {:noreply, put_flash(socket, :error, "Native secret handoff is deliberately deferred")}

      {:error, :native_pre_start_not_supported} ->
        {:noreply,
         put_flash(socket, :error, "Native pre-start actions are deliberately deferred")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, "A deployment for this project and target is already active")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not queue native deployment: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:deployment_changed, _id}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    input = Deployments.get_deployment_input!(socket.assigns.deployment_input_id)

    assign(socket,
      deployment_input: input,
      native_deployments: NativeDeployments.list_for_input(input.id)
    )
  end

  def native_state_class(:succeeded), do: "badge-success"
  def native_state_class(:failed), do: "badge-error"
  def native_state_class(:cancelled), do: "badge-warning"
  def native_state_class(_state), do: "badge-info"

  def input_state_class(:staged), do: "badge-success"
  def input_state_class(:failed), do: "badge-error"
  def input_state_class(_state), do: "badge-warning"

  def short_revision(nil), do: "—"
  def short_revision(revision), do: String.slice(revision, 0, 12)

  def format_time(nil), do: "—"
  def format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
