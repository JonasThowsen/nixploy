defmodule Nixploy.Notifications do
  @moduledoc "Bridges durable PostgreSQL notifications into local Phoenix PubSub."

  use GenServer

  alias Nixploy.Repo

  @channel "nixploy_deployments"
  @server Nixploy.PostgresNotifications
  @topic "deployments"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def connection_options do
    Repo.config()
    |> Keyword.drop([:name, :pool, :pool_size, :telemetry_prefix, :otp_app])
    |> Keyword.merge(name: @server, auto_reconnect: true)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(Nixploy.PubSub, @topic)
  end

  def subscribe(deployment_id) do
    Phoenix.PubSub.subscribe(Nixploy.PubSub, topic(deployment_id))
  end

  def publish(deployment_id) do
    payload = to_string(deployment_id)

    broadcast_deployment(payload)
    notify(payload)
  end

  def publish_service_status(service_id) do
    payload = "service:#{service_id}"

    broadcast_service_status(to_string(service_id))
    notify(payload)
  end

  defp notify(payload) do
    case Repo.query("SELECT pg_notify($1, $2)", [@channel, payload]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(:ok) do
    case Postgrex.Notifications.listen(@server, @channel) do
      {:ok, listen_ref} -> {:ok, %{listen_ref: listen_ref}}
      {:eventually, listen_ref} -> {:ok, %{listen_ref: listen_ref}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(
        {:notification, _pid, listen_ref, @channel, payload},
        %{listen_ref: listen_ref} = state
      ) do
    broadcast_payload(payload)
    {:noreply, state}
  end

  defp broadcast_payload("service:" <> service_id), do: broadcast_service_status(service_id)
  defp broadcast_payload(deployment_id), do: broadcast_deployment(deployment_id)

  defp broadcast_deployment(deployment_id) do
    message = {:deployment_changed, deployment_id}
    Phoenix.PubSub.broadcast(Nixploy.PubSub, @topic, message)
    Phoenix.PubSub.broadcast(Nixploy.PubSub, topic(deployment_id), message)
  end

  defp broadcast_service_status(service_id) do
    Phoenix.PubSub.broadcast(
      Nixploy.PubSub,
      @topic,
      {:service_status_changed, service_id}
    )
  end

  defp topic(deployment_id), do: "deployment:#{deployment_id}"
end
