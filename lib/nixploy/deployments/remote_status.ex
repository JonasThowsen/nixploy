defmodule Nixploy.Deployments.RemoteStatus do
  @moduledoc "Reads exact remote runtime identity through the packaged CLI without application mutation."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @timeout :timer.seconds(45)
  @max_output 65_536

  def observe(deployment, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    key = {__MODULE__, make_ref()}
    Process.put(key, %{observation: nil, error: nil})
    on_line = fn line -> consume(line, deployment, key) end

    result = execute.(command(deployment, opts), on_line: on_line)
    state = Process.delete(key)

    case {result, state} do
      {_result, %{error: reason}} when not is_nil(reason) ->
        {:error, reason}

      {{:ok, %{exit_status: 0, output_truncated?: false}}, %{observation: observation}}
      when is_map(observation) ->
        {:ok, observation}

      {{:ok, %{output_truncated?: true}}, _state} ->
        {:error, :status_output_too_large}

      {{:ok, %{exit_status: 0}}, _state} ->
        {:error, :status_observation_missing}

      {{:ok, %{exit_status: status}}, _state} ->
        {:error, {:status_failed, status}}

      {{:error, reason}, _state} ->
        {:error, reason}

      _other ->
        {:error, :status_observation_missing}
    end
  end

  def command(deployment, opts \\ []) do
    input = deployment.deployment_input

    executable =
      Keyword.get_lazy(opts, :executable, fn ->
        Application.fetch_env!(:nixploy, :remote_cli_executable)
      end)

    args = [
      "status",
      "--target",
      deployment.target,
      "--source",
      input.store_path,
      "--git-revision",
      input.source_revision,
      "--repository-identity",
      input.source_repository,
      "--configuration-digest",
      input.configuration_digest,
      "--operation-id",
      deployment.id,
      "--resource-key",
      deployment.resource_prefix
    ]

    args = optional(args, "--container-name", deployment.container_name)
    args = optional(args, "--image-reference", deployment.image_reference)
    args = optional(args, "--image-id", deployment.image_id)
    args = optional(args, "--expected-port", deployment.selected_port)

    %Command{
      executable: executable,
      args: args,
      timeout: @timeout,
      max_output_bytes: @max_output
    }
  end

  defp consume(line, deployment, key) do
    state = Process.get(key)

    case Jason.decode(line) do
      {:ok, %{"schema" => "nixploy.status/v1"} = observation} ->
        case validate(observation, deployment) do
          :ok ->
            if state.observation,
              do: Process.put(key, %{state | error: :duplicate_status_observation}),
              else: Process.put(key, %{state | observation: observation})

          {:error, reason} ->
            Process.put(key, %{state | error: reason})
        end

      _diagnostic ->
        :ok
    end
  end

  defp validate(observation, deployment) do
    booleans = ~w(container_verified ingress_available healthy converged)
    identity = observation["target_identity"]
    local_health = observation["target_local_health"]
    public_health = observation["public_health"]
    metrics = observation["metrics"]

    cond do
      observation["operation_id"] != deployment.id ->
        {:error, :status_operation_mismatch}

      observation["resource_key"] != deployment.resource_prefix ->
        {:error, :status_resource_mismatch}

      observation["project"] != deployment.project or observation["target"] != deployment.target ->
        {:error, :status_target_mismatch}

      observation["connection"] != deployment.resource_prefix ->
        {:error, :status_connection_mismatch}

      not valid_target_identity?(identity) ->
        {:error, :status_target_identity_invalid}

      not Enum.all?(booleans, &is_boolean(observation[&1])) ->
        {:error, :status_shape_invalid}

      not valid_port?(observation["active_port"]) or
          not valid_port?(observation["expected_port"]) ->
        {:error, :status_shape_invalid}

      observation["container_verified"] and not valid_container?(observation, deployment) ->
        {:error, :status_container_mismatch}

      not valid_ingress?(observation, deployment) ->
        {:error, :status_ingress_mismatch}

      not valid_health?(local_health) or not valid_public_health?(public_health) ->
        {:error, :status_health_invalid}

      not valid_metrics?(metrics) ->
        {:error, :status_metrics_invalid}

      not valid_observed_at?(observation["observed_at"]) ->
        {:error, :status_timestamp_invalid}

      true ->
        :ok
    end
  end

  defp valid_target_identity?(%{"host" => host, "user" => user, "port" => port}),
    do:
      is_binary(host) and host != "" and byte_size(host) <= 255 and is_binary(user) and
        user != "" and byte_size(user) <= 255 and is_integer(port) and port in 1..65_535

  defp valid_target_identity?(_identity), do: false

  defp valid_port?(nil), do: true
  defp valid_port?(port), do: is_integer(port) and port in 1..65_535

  defp valid_container?(observation, deployment) do
    observation["container_name"] == deployment.container_name and
      observation["container_id"] == deployment.container_id and
      observation["image_reference"] == deployment.image_reference and
      observation["image_id"] == deployment.image_id and
      observation["revision"] == deployment.deployment_input.source_revision and
      is_binary(observation["container_state"])
  end

  defp valid_ingress?(observation, deployment) do
    resource = deployment.resource_prefix
    slot = observation["active_slot"]

    observation["caddy_route_id"] == "nixploy-route-#{resource}" and
      observation["caddy_proxy_id"] == "nixploy-proxy-#{resource}" and
      slot in ["blue", "green"] and observation["active_port"] == deployment.selected_port and
      observation["caddy_upstream"] == "127.0.0.1:#{deployment.selected_port}"
  end

  defp valid_health?(%{"healthy" => healthy, "endpoint" => endpoint}),
    do: is_boolean(healthy) and is_binary(endpoint) and byte_size(endpoint) <= 2_048

  defp valid_health?(_health), do: false

  defp valid_public_health?(%{"healthy" => healthy, "status_code" => status, "error" => error}),
    do:
      is_boolean(healthy) and (is_nil(status) or (is_integer(status) and status in 100..599)) and
        (is_nil(error) or (is_binary(error) and byte_size(error) <= 255))

  defp valid_public_health?(_health), do: false

  defp valid_metrics?(metrics) when is_map(metrics) do
    Enum.all?(~w(cpu_percent memory_usage memory_percent pids network_io block_io), fn key ->
      is_nil(metrics[key]) or (is_binary(metrics[key]) and byte_size(metrics[key]) <= 255)
    end)
  end

  defp valid_metrics?(_metrics), do: false

  defp valid_observed_at?(value) when is_binary(value),
    do: match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))

  defp valid_observed_at?(_value), do: false

  defp optional(args, _flag, nil), do: args
  defp optional(args, flag, value), do: args ++ [flag, to_string(value)]
end
