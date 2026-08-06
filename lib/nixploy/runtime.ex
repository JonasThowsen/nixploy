defmodule Nixploy.Runtime do
  @moduledoc "Worker-observed managed application runtime keyed by host-owned application identity."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Deployments.{NativeDeployment, NativeEvent}

  alias Nixploy.{
    Audit,
    ManagedApplications,
    NativeDeployments,
    Notifications,
    Repo,
    RuntimeLogSnapshot
  }

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
      :caddy_route_id,
      :caddy_upstream,
      :target_local_health,
      :public_health,
      :metrics,
      managed?: true
    ]
  end

  defmodule Machine do
    @moduledoc false
    defstruct [
      :hostname,
      :target_host,
      :observed_at,
      :architecture,
      :os,
      :kernel,
      :distribution,
      :distribution_version,
      :cpu_count,
      :memory_total_bytes,
      :memory_used_bytes,
      :memory_percent,
      :swap_total_bytes,
      :swap_used_bytes,
      :storage_total_bytes,
      :storage_used_bytes,
      :storage_available_bytes,
      :storage_percent,
      :storage_driver,
      :uptime,
      :rootless,
      :containers_total,
      :containers_running,
      :containers_stopped,
      :images_total,
      :podman_version
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
      :log_status,
      :logs_fetched_at,
      :logs_truncated,
      :published_ports,
      :target_host,
      :target_user,
      :target_port,
      :resource_key,
      :connection,
      :connection_state,
      :stale?,
      :observation_error,
      :caddy_route_id,
      :caddy_upstream,
      :target_local_health,
      :public_health
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

  def target_machine do
    machine =
      ManagedApplications.list()
      |> latest_deployments()
      |> Map.values()
      |> latest_observations()
      |> Map.values()
      |> Enum.find_value(&machine_from_observation/1)

    if machine, do: {:ok, machine}, else: {:error, :remote_observation_unavailable}
  end

  def workload_details(application_key) when is_binary(application_key) do
    with {:ok, inventory} <- inventory(),
         %Workload{} = workload <- Enum.find(inventory.workloads, &(&1.id == application_key)) do
      log_snapshot = Repo.get_by(RuntimeLogSnapshot, application_key: application_key)
      log = visible_log(log_snapshot)

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
         cpu_percent: metric(workload, "cpu_percent"),
         memory_percent: metric(workload, "memory_percent"),
         memory_usage: metric(workload, "memory_usage"),
         pids: metric(workload, "pids"),
         network_io: metric(workload, "network_io"),
         block_io: metric(workload, "block_io"),
         metrics_error: metrics_error(workload),
         logs: log_content(log),
         logs_error: log_error(log_snapshot, log),
         log_line_count: (log && log.line_count) || 0,
         log_status: log_status(log_snapshot, log),
         logs_fetched_at: log && log.fetched_at,
         logs_truncated: (log && log.truncated) || false,
         published_ports: [],
         target_host: workload.target_host,
         target_user: workload.target_user,
         target_port: workload.target_port,
         resource_key: workload.resource_key,
         connection: workload.connection,
         connection_state: workload.connection_state,
         stale?: workload.stale?,
         observation_error: workload.error,
         caddy_route_id: workload.caddy_route_id,
         caddy_upstream: workload.caddy_upstream,
         target_local_health: workload.target_local_health,
         public_health: workload.public_health
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

  def request_refresh(application_key, operator) when is_binary(application_key) do
    with {:ok, _application} <- ManagedApplications.fetch(application_key),
         %NativeDeployment{} = deployment <- latest_deployment(application_key) do
      NativeDeployments.enqueue_status_refresh(deployment.id, operator)
    else
      nil -> {:error, :remote_deployment_unavailable}
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

  def request_logs(application_key, operator, opts \\ []) when is_binary(application_key) do
    worker = Keyword.get(opts, :worker, Nixploy.Deployments.RemoteLogsWorker)
    request_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    with {:ok, _application} <- ManagedApplications.fetch(application_key),
         %NativeDeployment{} = deployment <- latest_deployment(application_key) do
      result =
        Multi.new()
        |> Multi.run(:snapshot, fn repo, _changes ->
          request_log_snapshot(repo, application_key, deployment.id, request_id, now)
        end)
        |> Oban.insert(:job, fn %{snapshot: snapshot} ->
          worker.new(%{
            application_key: application_key,
            native_deployment_id: deployment.id,
            request_id: snapshot.request_id
          })
        end)
        |> Multi.insert(:audit, fn %{snapshot: snapshot} ->
          Audit.changeset(
            operator,
            :runtime_logs_requested,
            :runtime_log_snapshot,
            snapshot.id,
            outcome: :requested,
            metadata: %{
              "application_key" => application_key,
              "native_deployment_id" => deployment.id,
              "resource_key" => deployment.resource_prefix
            }
          )
        end)
        |> Repo.transaction()

      case result do
        {:ok, %{snapshot: snapshot, job: job}} -> {:ok, snapshot, job}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    else
      nil -> {:error, :remote_deployment_unavailable}
      error -> error
    end
  end

  def complete_logs(application_key, request_id, attrs) do
    update_log_snapshot(application_key, request_id, fn snapshot ->
      now = DateTime.utc_now()

      snapshot
      |> RuntimeLogSnapshot.available_changeset(
        attrs
        |> Map.put(:fetched_at, now)
        |> Map.put(:expires_at, DateTime.add(now, 300, :second))
      )
    end)
  end

  def fail_logs(application_key, request_id, reason) do
    update_log_snapshot(application_key, request_id, fn snapshot ->
      now = DateTime.utc_now()

      RuntimeLogSnapshot.failed_changeset(snapshot, %{
        failure: %{message: inspect(reason, limit: 10, printable_limit: 1_000)},
        fetched_at: now,
        expires_at: DateTime.add(now, 300, :second)
      })
    end)
  end

  defp latest_deployments(applications) do
    keys = Enum.map(applications, & &1.key)

    NativeDeployment
    |> join(:inner, [deployment], input in assoc(deployment, :deployment_input))
    |> where(
      [deployment, input],
      input.application_key in ^keys and deployment.state == :succeeded
    )
    |> order_by([deployment], desc: deployment.inserted_at)
    |> preload([:deployment_input])
    |> Repo.all()
    |> Enum.reduce(%{}, fn deployment, acc ->
      Map.put_new(acc, deployment.deployment_input.application_key, deployment)
    end)
  end

  defp latest_deployment(application_key) do
    NativeDeployment
    |> join(:inner, [deployment], input in assoc(deployment, :deployment_input))
    |> where(
      [deployment, input],
      input.application_key == ^application_key and deployment.state == :succeeded
    )
    |> order_by([deployment], desc: deployment.inserted_at)
    |> preload([:deployment_input])
    |> limit(1)
    |> Repo.one()
  end

  defp request_log_snapshot(repo, application_key, deployment_id, request_id, now) do
    attrs = %{
      application_key: application_key,
      native_deployment_id: deployment_id,
      request_id: request_id,
      requested_at: now
    }

    case repo.get_by(RuntimeLogSnapshot, application_key: application_key) do
      nil -> %RuntimeLogSnapshot{} |> RuntimeLogSnapshot.request_changeset(attrs) |> repo.insert()
      snapshot -> snapshot |> RuntimeLogSnapshot.request_changeset(attrs) |> repo.update()
    end
  end

  defp update_log_snapshot(application_key, request_id, changeset_fun) do
    result =
      Repo.transaction(fn ->
        snapshot =
          RuntimeLogSnapshot
          |> where([snapshot], snapshot.application_key == ^application_key)
          |> lock("FOR UPDATE")
          |> Repo.one()

        cond do
          is_nil(snapshot) -> Repo.rollback(:request_not_found)
          snapshot.request_id != request_id -> Repo.rollback(:stale_request)
          true -> snapshot |> changeset_fun.() |> Repo.update!()
        end
      end)

    case result do
      {:ok, snapshot} ->
        _ = Notifications.publish(snapshot.native_deployment_id)
        {:ok, snapshot}

      {:error, reason} ->
        {:error, reason}
    end
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
    identity = metadata["target_identity"] || %{}
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
      target_host: identity["host"] || target["host"],
      target_user: identity["user"] || target["user"],
      target_port: identity["port"] || target["port"],
      resource_key: deployment.resource_prefix,
      connection: deployment.resource_prefix,
      connection_state: connection_state(observation, error),
      state: if(verified?, do: "running", else: "unavailable"),
      status: observation_status(observation, metadata, stale?),
      slot: metadata["active_slot"] || deployment.selected_slot,
      container_id: metadata["container_id"] || deployment.container_id,
      container_name: metadata["container_name"] || deployment.container_name,
      image: metadata["image_reference"] || deployment.image_reference,
      image_id: metadata["image_id"] || deployment.image_id,
      revision: metadata["revision"] || deployment.deployment_input.source_revision,
      observed_at: observed_at,
      stale?: stale?,
      error: error,
      deployment_id: deployment.id,
      deployed_at: parse_datetime(metadata["deployed_at"]) || deployment.finished_at,
      caddy_route_id: metadata["caddy_route_id"],
      caddy_upstream: metadata["caddy_upstream"],
      target_local_health: metadata["target_local_health"],
      public_health: metadata["public_health"],
      metrics: metadata["metrics"]
    }
  end

  defp machine_from_observation(%NativeEvent{metadata: metadata, inserted_at: observed_at}) do
    host = metadata["target_identity"] || %{}
    metrics = metadata["host_metrics"]

    if is_map(metrics) do
      memory_total = metrics["memory_total_bytes"]
      memory_used = max(memory_total - metrics["memory_free_bytes"], 0)
      storage_total = metrics["storage_total_bytes"]
      storage_used = metrics["storage_used_bytes"]

      struct(Machine,
        hostname: metrics["hostname"],
        target_host: host["host"],
        observed_at: observed_at,
        architecture: metrics["architecture"],
        os: metrics["os"],
        kernel: metrics["kernel"],
        distribution: metrics["distribution"],
        distribution_version: metrics["distribution_version"],
        cpu_count: metrics["cpu_count"],
        memory_total_bytes: memory_total,
        memory_used_bytes: memory_used,
        memory_percent: percent(memory_used, memory_total),
        swap_total_bytes: metrics["swap_total_bytes"],
        swap_used_bytes: max(metrics["swap_total_bytes"] - metrics["swap_free_bytes"], 0),
        storage_total_bytes: storage_total,
        storage_used_bytes: storage_used,
        storage_available_bytes: max(storage_total - storage_used, 0),
        storage_percent: percent(storage_used, storage_total),
        storage_driver: metrics["storage_driver"],
        uptime: metrics["uptime"],
        rootless: metrics["rootless"],
        containers_total: metrics["containers_total"],
        containers_running: metrics["containers_running"],
        containers_stopped: metrics["containers_stopped"],
        images_total: metrics["images_total"],
        podman_version: metrics["podman_version"]
      )
    end
  end

  defp percent(value, total) when is_integer(value) and is_integer(total) and total > 0,
    do: Float.round(value / total * 100, 1)

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

  defp metric(%Workload{metrics: metrics}, key) when is_map(metrics), do: metrics[key]
  defp metric(_workload, _key), do: nil

  defp metrics_error(%Workload{metrics: metrics}) when is_map(metrics), do: nil
  defp metrics_error(_workload), do: :remote_detail_not_observed

  defp visible_log(%RuntimeLogSnapshot{status: :available, expires_at: expires_at} = snapshot) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: snapshot
  end

  defp visible_log(_snapshot), do: nil

  defp log_content(%RuntimeLogSnapshot{} = snapshot), do: snapshot.content
  defp log_content(_snapshot), do: nil

  defp log_error(%RuntimeLogSnapshot{status: :failed, failure: failure}, _visible),
    do: (failure || %{})["message"] || "Remote log observation failed"

  defp log_error(%RuntimeLogSnapshot{status: :available}, nil), do: :expired
  defp log_error(_snapshot, _visible), do: nil

  defp log_status(nil, _visible), do: :idle
  defp log_status(%RuntimeLogSnapshot{status: :available}, nil), do: :expired
  defp log_status(%RuntimeLogSnapshot{status: status}, _visible), do: status

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
