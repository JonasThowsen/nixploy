defmodule NixployWeb.DeploymentLive.Show do
  use NixployWeb, :live_view

  alias Nixploy.Deployments

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    input = Deployments.get_deployment_input!(id)

    {:ok,
     socket
     |> assign(:page_title, "Deployment input")
     |> assign(:deployment_input, input)}
  end

  def input_state_class(:staged), do: "badge-success"
  def input_state_class(:failed), do: "badge-error"
  def input_state_class(_state), do: "badge-warning"

  def format_time(nil), do: "—"
  def format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
