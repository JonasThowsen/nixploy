defmodule Nixploy.Deployments.RemoteCliExecutor do
  @moduledoc "Invokes the packaged remote-target CLI for one exact immutable release."

  alias Nixploy.Deployments.{
    DeploymentPolicy,
    EventProtocol,
    LocalStoreInput,
    NativeDeployment,
    RemotePlan,
    ResourceIdentity
  }

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @timeout :timer.hours(1)
  @protocol_bytes 1_048_576
  @diagnostic_bytes 65_536

  def deploy(%NativeDeployment{} = deployment, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    workspace_root = Keyword.get(opts, :workspace_root, workspace_root())
    workspace = Path.join(workspace_root, deployment.id)

    with :ok <- private_workspace(workspace) do
      try do
        with {:ok, fresh_plan} <- read_plan(deployment, workspace, opts),
             {:ok, policy} <- evaluate_policy(deployment, fresh_plan, opts),
             :ok <- record_policy_stage(policy, fresh_plan, opts) do
          command = command(deployment, workspace, opts)
          state_key = {__MODULE__, make_ref()}
          Process.put(state_key, %{protocol: EventProtocol.initial(), error: nil, outcome: nil})

          on_line = fn line -> consume_line(line, deployment, opts, state_key) end
          execution_opts = Keyword.take(opts, [:cancelled?]) |> Keyword.put(:on_line, on_line)
          execution_result = execute.(command, execution_opts)
          protocol_result = protocol_result(Process.get(state_key))
          Process.delete(state_key)

          case {execution_result, protocol_result} do
            {{:ok, %{output_truncated?: true}}, _protocol} ->
              {:error, :remote_cli_output_too_large}

            {{:error, reason}, _protocol} ->
              {:error, reason}

            {{:ok, %{exit_status: 0}}, :succeeded} ->
              :ok

            {{:ok, %{exit_status: status}}, {:failed, code}} ->
              {:error, {:remote_cli_reported_failure, status, code}}

            {{:ok, %{exit_status: status}}, {:error, reason}} ->
              {:error, {:remote_cli_protocol_error, status, reason}}

            {{:ok, %{exit_status: status}}, :succeeded} ->
              {:error, {:remote_cli_exit_mismatch, status}}
          end
        end
      after
        File.rm_rf(workspace)
      end
    end
  end

  @doc false
  def command(%NativeDeployment{} = deployment, workspace, opts \\ []) do
    input = deployment.deployment_input
    executable = Keyword.get_lazy(opts, :executable, &executable!/0)
    resource_key = ResourceIdentity.derive!(deployment.project, deployment.target)

    unless immutable_store_path?(input.store_path),
      do: raise(ArgumentError, "remote CLI source must be one immutable Nix store path")

    unless is_binary(input.source_revision) and
             Regex.match?(~r/^[0-9a-f]{40}$/, input.source_revision),
           do: raise(ArgumentError, "remote CLI requires one persisted full Git revision")

    unless is_binary(input.source_repository),
      do: raise(ArgumentError, "remote CLI requires persisted repository identity")

    %Command{
      executable: executable,
      args: [
        "deploy",
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
        resource_key,
        "--events",
        "jsonl"
      ],
      cd: workspace,
      env: %{
        "HOME" => workspace,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null"
      },
      timeout: @timeout,
      max_output_bytes: @protocol_bytes + @diagnostic_bytes
    }
  end

  defp read_plan(deployment, workspace, opts) do
    plan_opts = [
      execute: Keyword.get(opts, :execute, &Execution.run/2),
      executable: Keyword.get_lazy(opts, :executable, &executable!/0),
      workspace: workspace,
      env: %{
        "HOME" => workspace,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null"
      }
    ]

    case Keyword.get(opts, :plan, RemotePlan) do
      module when is_atom(module) -> module.read(deployment, plan_opts)
      callback when is_function(callback, 1) -> callback.(deployment)
    end
  end

  defp evaluate_policy(deployment, fresh_plan, opts) do
    case Keyword.get(opts, :policy, DeploymentPolicy) do
      module when is_atom(module) -> module.evaluate(deployment, plan: fresh_plan)
      callback when is_function(callback, 2) -> callback.(deployment, fresh_plan)
      callback when is_function(callback, 1) -> callback.(deployment)
    end
  end

  defp record_policy_stage(policy, fresh_plan, opts) do
    message =
      if policy.allow?,
        do: "Pinned deployment policy allowed the immutable remote plan",
        else: "Pinned deployment policy denied in shadow mode; evidence retained"

    apply_stage(
      %{
        stage: :preparing,
        message: message,
        attrs: %{
          metadata: %{
            policy_contract_version: policy[:contract_version],
            policy_mode: policy.mode,
            policy_code: policy.code,
            policy_findings: policy[:findings] || [],
            policy_duration_ms: policy[:duration_ms],
            policy_payload_digest: policy.payload_digest,
            policy_plan_digest: policy[:plan_digest],
            policy_component_digest: policy.component_digest,
            fresh_plan_digest: LocalStoreInput.digest(fresh_plan)
          }
        }
      },
      opts
    )
  end

  defp consume_line(line, deployment, opts, state_key) do
    state = Process.get(state_key)

    if state.error do
      :ok
    else
      case EventProtocol.consume(line, state.protocol, deployment.id) do
        {:diagnostic, diagnostic, protocol} ->
          if callback = Keyword.get(opts, :on_diagnostic), do: callback.(diagnostic)
          Process.put(state_key, %{state | protocol: protocol})

        {:event, event, protocol} ->
          apply_event(event, protocol, state, opts, state_key)

        {:error, reason} ->
          Process.put(state_key, %{state | error: reason})
      end
    end
  end

  defp apply_event(%{type: :stage} = event, protocol, state, opts, state_key) do
    case apply_stage(event, opts) do
      :ok -> Process.put(state_key, %{state | protocol: protocol})
      {:error, reason} -> Process.put(state_key, %{state | protocol: protocol, error: reason})
    end
  end

  defp apply_event(
         %{type: :terminal, stage: :succeeded} = event,
         protocol,
         state,
         opts,
         state_key
       ) do
    case apply_stage(event, opts) do
      :ok -> Process.put(state_key, %{state | protocol: protocol, outcome: :succeeded})
      {:error, reason} -> Process.put(state_key, %{state | protocol: protocol, error: reason})
    end
  end

  defp apply_event(
         %{type: :terminal, stage: :failed, code: code},
         protocol,
         state,
         _opts,
         state_key
       ) do
    Process.put(state_key, %{state | protocol: protocol, outcome: {:failed, code}})
  end

  defp apply_stage(event, opts) do
    case Keyword.get(opts, :stage) do
      callback when is_function(callback, 3) -> callback.(event.stage, event.message, event.attrs)
      _callback -> :ok
    end
  end

  defp protocol_result(%{error: reason}) when not is_nil(reason), do: {:error, reason}
  defp protocol_result(%{protocol: %{terminal?: false}}), do: {:error, :missing_terminal_event}
  defp protocol_result(%{outcome: outcome}), do: outcome

  defp executable! do
    executable = Application.fetch_env!(:nixploy, :remote_cli_executable)

    if String.starts_with?(executable, "/nix/store/") and Path.basename(executable) == "nixploy",
      do: executable,
      else: raise("configured remote CLI must be the packaged /nix/store/.../bin/nixploy")
  end

  defp immutable_store_path?(path) when is_binary(path) do
    Path.dirname(path) == "/nix/store" and Path.basename(path) != ""
  end

  defp immutable_store_path?(_path), do: false

  defp private_workspace(workspace) do
    with :ok <- File.mkdir_p(workspace), :ok <- File.chmod(workspace, 0o700) do
      :ok
    else
      {:error, _reason} -> {:error, :remote_cli_workspace_unavailable}
    end
  end

  defp workspace_root do
    Application.get_env(:nixploy, :operation_workspace_root, "/var/lib/nixploy/operations")
  end
end
