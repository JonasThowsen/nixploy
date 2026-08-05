defmodule Nixploy.Application do
  @moduledoc false

  use Application

  alias Nixploy.RuntimeRole

  @impl true
  def start(_type, _args) do
    children = children(RuntimeRole.current())
    opts = [strategy: :one_for_one, name: Nixploy.Supervisor]

    Supervisor.start_link(children, opts)
  end

  @doc false
  @spec children(RuntimeRole.t()) :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children(role) do
    [Nixploy.Repo] ++
      worker_preflight_children(role) ++
      [
        {Oban, Application.fetch_env!(:nixploy, Oban)},
        {Phoenix.PubSub, name: Nixploy.PubSub}
      ] ++ web_children(role)
  end

  defp worker_preflight_children(role) do
    if RuntimeRole.worker?(role),
      do: [Nixploy.Deployments.PreparationWorkspaceReconciler],
      else: []
  end

  defp web_children(role) do
    if RuntimeRole.web?(role) do
      [
        {Postgrex.Notifications, Nixploy.Notifications.connection_options()},
        Nixploy.Notifications,
        NixployWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:nixploy, :dns_cluster_query) || :ignore},
        NixployWeb.Endpoint
      ]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    if RuntimeRole.web?() do
      NixployWeb.Endpoint.config_change(changed, removed)
    end

    :ok
  end
end
