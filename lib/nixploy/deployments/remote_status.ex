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

    cond do
      observation["operation_id"] != deployment.id ->
        {:error, :status_operation_mismatch}

      observation["resource_key"] != deployment.resource_prefix ->
        {:error, :status_resource_mismatch}

      not Enum.all?(booleans, &is_boolean(observation[&1])) ->
        {:error, :status_shape_invalid}

      not is_nil(observation["active_port"]) and not is_integer(observation["active_port"]) ->
        {:error, :status_shape_invalid}

      true ->
        :ok
    end
  end

  defp optional(args, _flag, nil), do: args
  defp optional(args, flag, value), do: args ++ [flag, to_string(value)]
end
