defmodule Nixploy.Runtime do
  @moduledoc "Worker-observed managed application runtime keyed by host-owned application identity."

  import Ecto.Query, warn: false

  alias Nixploy.Deployments.{NativeDeployment, NativeEvent}
  alias Nixploy.{ManagedApplications, NativeDeployments, Repo}

  @stale_after_seconds 300

  defmodule Inventory do
    @moduledoc false
    defstruct [:hostname, :runtime_user, :observed_at, workloads: []]
  end

  defmodule Workload do
    @moduledoc false
    defstruct [
      :id,
      :name,
      :application_key,
      :project,
      :target,
      :target_host,
      :target_user,
      :target_port,
      :resource_key,
      :connection,
      :connection_state,
      :state,
      :status,
      :slot,
      :container_id,
      :container_name,
      :image,
      :image_id,
      :revision,
      :observed_at,
      :stale?,
      :error,
      :deployment_id,
      :deployed_at,
      managed?: true
    ]
  end

  defmodule Details do
    @moduledoc false
    defstruct [
      :id,
      :state,
      :status,
      :slot,
      :container_id,
      :container_name,
      :image,
      :image_id,
      :revision,
      :started_at,
      :observed_at,
      :health,
      :cpu_percent,
      :memory_percent,
      :memory_usage,
      :pids,
      :network_io,
      :block_io,
      :metrics_error,
      :logs,
      :logs_error,
      :log_line_count,
      :published_ports,
      :target_host,
      :target_user,
      :target_port,
      :resource_key,
      :connection,
      :connection_state,
      :stale?,
      :observation_error
    ]
  end

  def inventory do
    applications = ManagedApplications.list()
    deployments = latest_deployments(applications)
    observations = latest_observations(Map.values(deployments))
    observed_at = DateTime.utc_now()

    workloads =
      Enum.map(applications, fn application ->
        deployment = deployments[application.key]
        observation = if deployment, do: observations[deployment.id]
        workload(application, deployment, observation, observed_at)
      end)

    {:ok,
     %Inventory{
       hostname: "managed remote targets",
       runtime_user: "worker",
       observed_at: observed_at,
       workloads: workloads
     }}
  end

  def workload_details(application_key) when is_binary(application_key) do
    with {:ok, inventory} <- inventory(),
         %Workload{} = workload <- Enum.find(inventory.workloads, &(&1.id == application_key)) do
      {:ok,
       struct(Details,
         id: workload.id,
         state: workload.state,
         status: workload.status,
         slot: workload.slot,
         container_id: workload.container_id,
         container_name: workload.container_name,
         image: workload.image,
         image_id: workload.image_id,
         revision: workload.revision,
         started_at: workload.deployed_at,
         observed_at: workload.observed_at,
         health: health_label(workload),
         cpu_percent: nil,
         memory_percent: nil,
         memory_usage: nil,
         pids: nil,
         network_io: nil,
         block_io: nil,
         metrics_error: :remote_detail_not_observed,
         logs: nil,
         logs_error: nil,
         log_line_count: 0,
         published_ports: [],
         target_host: workload.target_host,
         target_user: workload.target_user,
         target_port: workload.target_port,
         resource_key: workload.resource_key,
         connection: workload.connection,
         connection_state: workload.connection_state,
         stale?: workload.stale?,
         observation_error: workload.error
       )}
    else
      nil -> {:error, :managed_application_not_found}
      error -> error
    end
  end

  def observe_health(application_key) when is_binary(application_key) do
    with {:ok, inventory} <- inventory(),
         %Workload{} = workload <- Enum.find(inventory.workloads, &(&1.id == application_key)),
         true <- not is_nil(workload.observed_at) do
      {:ok,
       %{
         status: health_status(workload),
         status_code: nil,
         container_state: workload.state,
         endpoint: "target-local health from the latest worker observation",
         observed_at: workload.observed_at,
         stale?: workload.stale?
       }}
    else
      nil -> {:error, :managed_application_not_found}
      false -> {:error, :remote_observation_unavailable}
      error -> error
    end
  end

  def request_refresh_all(operator) do
    ManagedApplications.list()
    |> latest_deployments()
    |> Enum.reduce(%{queued: 0, unavailable: []}, fn {application_key, deployment}, acc ->
      case NativeDeployments.enqueue_status_refresh(deployment.id, operator) do
        {:ok, _job} -> %{acc | queued: acc.queued + 1}
        {:error, reason} -> %{acc | unavailable: [{application_key, reason} | acc.unavailable]}
      end
    end)
    |> then(&{:ok, &1})
  end

  def request_refresh_all(_operator, []), do: {:ok, %{queued: 0, unavailable: []}}

  defp latest_deployments(applications) do
    keys = Enum.map(applications, & &1.key)

    NativeDeployment
    |> join(:inner, [deployment], input in assoc(deployment, :deployment_input))
    |> where([_deployment, input], input.application_key in ^keys)
    |> order_by([deployment], desc: deployment.inserted_at)
    |> preload([:deployment_input])
    |> Repo.all()
    |> Enum.reduce(%{}, fn deployment, acc ->
      Map.put_new(acc, deployment.deployment_input.application_key, deployment)
    end)
  end

  defp latest_observations([]), do: %{}

  defp latest_observations(deployments) do
    ids = Enum.map(deployments, & &1.id)

    NativeEvent
    |> where([event], event.native_deployment_id in ^ids and event.stage == "observation")
    |> order_by([event], desc: event.inserted_at, desc: event.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn event, acc -> Map.put_new(acc, event.native_deployment_id, event) end)
  end

  defp workload(application, nil, _observation, _now) do
    %Workload{
      id: application.key,
      name: application.project,
      application_key: application.key,
      project: application.project,
      target: application.target,
      target_host: nil,
      target_user: nil,
      target_port: nil,
      resource_key: nil,
      connection: nil,
      connection_state: "not observed",
      state: "unavailable",
      status: "no deployment",
      stale?: true,
      error: "No immutable deployment exists for this managed application"
    }
  end

  defp workload(application, deployment, observation, now) do
    target = deployment.deployment_input.derived_snapshot["target"] || %{}
    metadata = if observation, do: observation.metadata || %{}, else: %{}
    observed_at = observation && observation.inserted_at
    stale? = stale?(observed_at, now)
    error = metadata["error"]
    verified? = metadata["container_verified"] == true

    %Workload{
      id: application.key,
      name: application.project,
      application_key: application.key,
      project: application.project,
      target: application.target,
      target_host: metadata["target_host"] || target["host"],
      target_user: metadata["target_user"] || target["user"],
      target_port: metadata["target_port"] || target["port"],
      resource_key: deployment.resource_prefix,
      connection: deployment.resource_prefix,
      connection_state: connection_state(observation, error),
      state: if(verified?, do: "running", else: "unavailable"),
      status: observation_status(observation, metadata, stale?),
      slot: deployment.selected_slot,
      container_id: metadata["container_id"] || deployment.container_id,
      container_name: deployment.container_name,
      image: deployment.image_reference,
      image_id: metadata["image_id"] || deployment.image_id,
      revision: deployment.deployment_input.source_revision,
      observed_at: observed_at,
      stale?: stale?,
      error: error,
      deployment_id: deployment.id,
      deployed_at: deployment.finished_at
    }
  end

  defp connection_state(nil, _error), do: "not observed"
  defp connection_state(_observation, error) when is_binary(error), do: "error"
  defp connection_state(_observation, _error), do: "connected"

  defp observation_status(nil, _metadata, _stale), do: "observation unavailable"

  defp observation_status(_observation, %{"error" => error}, _stale) when is_binary(error),
    do: "error"

  defp observation_status(_observation, _metadata, true), do: "stale"
  defp observation_status(_observation, %{"converged" => true}, false), do: "converged"
  defp observation_status(_observation, _metadata, false), do: "mismatch"

  defp stale?(nil, _now), do: true

  defp stale?(observed_at, now) do
    DateTime.diff(now, observed_at, :second) > @stale_after_seconds
  end

  defp health_status(%Workload{stale?: true}), do: :failed
  defp health_status(%Workload{status: "converged"}), do: :healthy
  defp health_status(_workload), do: :unhealthy

  defp health_label(workload), do: workload |> health_status() |> Atom.to_string()
end
