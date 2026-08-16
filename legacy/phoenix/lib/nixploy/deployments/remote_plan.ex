defmodule Nixploy.Deployments.RemotePlan do
  @moduledoc "Reads and validates the packaged fresh deployment plan before policy and effects."

  alias Nixploy.Deployments.{NativeDeployment, ResourceIdentity}
  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @timeout :timer.seconds(45)
  @max_output 65_536
  @effects ~w(
    build_image
    install_credentials
    load_remote_image
    run_fixed_pre_start
    start_inactive_slot
    check_target_local_health
    switch_exact_caddy_route
    independent_readback
  )

  def read(%NativeDeployment{} = deployment, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    key = {__MODULE__, make_ref()}
    Process.put(key, %{plan: nil, error: nil})
    result = execute.(command(deployment, opts), on_line: &consume(&1, deployment, key))
    state = Process.delete(key)

    case {result, state} do
      {_result, %{error: reason}} when not is_nil(reason) ->
        {:error, reason}

      {{:ok, %{exit_status: 0, output_truncated?: false}}, %{plan: plan}} when is_map(plan) ->
        {:ok, plan}

      {{:ok, %{output_truncated?: true}}, _state} ->
        {:error, :plan_output_too_large}

      {{:ok, %{exit_status: 0}}, _state} ->
        {:error, :plan_observation_missing}

      {{:ok, %{exit_status: status}}, _state} ->
        {:error, {:plan_failed, status}}

      {{:error, reason}, _state} ->
        {:error, reason}

      _other ->
        {:error, :plan_observation_missing}
    end
  end

  def command(%NativeDeployment{} = deployment, opts \\ []) do
    input = deployment.deployment_input

    executable =
      Keyword.get_lazy(opts, :executable, fn ->
        Application.fetch_env!(:nixploy, :remote_cli_executable)
      end)

    %Command{
      executable: executable,
      args: [
        "plan",
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
      ],
      cd: Keyword.get(opts, :workspace),
      env: Keyword.get(opts, :env, %{}),
      timeout: @timeout,
      max_output_bytes: @max_output
    }
  end

  defp consume(line, deployment, key) do
    state = Process.get(key)

    case Jason.decode(line) do
      {:ok, %{"schema" => "nixploy.plan/v1"} = plan} ->
        case validate(plan, deployment) do
          :ok when is_nil(state.plan) -> Process.put(key, %{state | plan: plan})
          :ok -> Process.put(key, %{state | error: :duplicate_plan_observation})
          {:error, reason} -> Process.put(key, %{state | error: reason})
        end

      _diagnostic ->
        :ok
    end
  end

  defp validate(plan, deployment) do
    input = deployment.deployment_input
    snapshot = input.derived_snapshot
    target = snapshot["target"] || %{}
    slots = target["slots"] || %{}
    run = target["run"] || %{}
    expected_resource = ResourceIdentity.derive!(deployment.project, deployment.target)
    candidate_slot = plan["candidate_slot"]
    candidate_port = plan["candidate_port"]
    active_slot = plan["active_slot"]
    active_port = plan["active_port"]

    cond do
      plan["operation_id"] != deployment.id ->
        {:error, :plan_operation_mismatch}

      plan["resource_key"] != expected_resource ->
        {:error, :plan_resource_mismatch}

      plan["project"] != snapshot["project"] or plan["target"] != deployment.target ->
        {:error, :plan_target_mismatch}

      plan["connection"] != expected_resource ->
        {:error, :plan_connection_mismatch}

      plan["image_output"] != target["image_output"] ->
        {:error, :plan_image_mismatch}

      plan["domain"] != target["domain"] ->
        {:error, :plan_domain_mismatch}

      candidate_slot not in ["blue", "green"] ->
        {:error, :plan_slot_invalid}

      candidate_port != slots[candidate_slot] ->
        {:error, :plan_port_mismatch}

      not valid_active?(active_slot, active_port, slots) ->
        {:error, :plan_active_invalid}

      active_slot == candidate_slot ->
        {:error, :plan_slot_invalid}

      plan["current_container"] != current_container(expected_resource, active_slot) ->
        {:error, :plan_container_mismatch}

      plan["caddy_route_id"] != "nixploy-route-#{expected_resource}" ->
        {:error, :plan_caddy_mismatch}

      plan["caddy_proxy_id"] != "nixploy-proxy-#{expected_resource}" ->
        {:error, :plan_caddy_mismatch}

      plan["health_endpoint"] !=
          "http://127.0.0.1:#{candidate_port}#{target["health_path"]}" ->
        {:error, :plan_health_mismatch}

      plan["pre_start_count"] != length(run["pre_start"] || []) ->
        {:error, :plan_action_count_mismatch}

      plan["credential_count"] != map_size(target["credential_references"] || %{}) ->
        {:error, :plan_credential_count_mismatch}

      plan["task_names"] != (target["tasks"] || %{}) |> Map.keys() |> Enum.sort() ->
        {:error, :plan_task_mismatch}

      plan["intended_effects"] != @effects ->
        {:error, :plan_effects_mismatch}

      not valid_target_identity?(plan["target_identity"]) ->
        {:error, :plan_target_identity_invalid}

      true ->
        :ok
    end
  end

  defp valid_active?(nil, nil, _slots), do: true
  defp valid_active?(slot, port, slots) when slot in ["blue", "green"], do: slots[slot] == port
  defp valid_active?(_slot, _port, _slots), do: false

  defp current_container(_resource, nil), do: nil
  defp current_container(resource, slot), do: "#{resource}-#{slot}"

  defp valid_target_identity?(%{"host" => host, "user" => user, "port" => port}),
    do: is_binary(host) and host != "" and is_binary(user) and user != "" and is_integer(port)

  defp valid_target_identity?(_identity), do: false
end
