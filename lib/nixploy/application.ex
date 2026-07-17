defmodule Nixploy.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NixployWeb.Telemetry,
      Nixploy.Repo,
      {DNSCluster, query: Application.get_env(:nixploy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Nixploy.PubSub},
      # Start a worker by calling: Nixploy.Worker.start_link(arg)
      # {Nixploy.Worker, arg},
      # Start to serve requests, typically the last entry
      NixployWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Nixploy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NixployWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
