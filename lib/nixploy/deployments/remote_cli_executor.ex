defmodule Nixploy.Deployments.RemoteCliExecutor do
  @moduledoc "Invokes the packaged remote-target CLI for one exact immutable release."

  alias Nixploy.Deployments.{NativeDeployment, ResourceIdentity}
  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @timeout :timer.hours(1)
  @diagnostic_bytes 65_536

  def deploy(%NativeDeployment{} = deployment, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    workspace_root = Keyword.get(opts, :workspace_root, workspace_root())
    workspace = Path.join(workspace_root, deployment.id)

    with :ok <- private_workspace(workspace) do
      try do
        command = command(deployment, workspace, opts)

        case execute.(command, Keyword.take(opts, [:cancelled?])) do
          {:ok, %{exit_status: 0, output_truncated?: false}} ->
            :ok

          {:ok, %{exit_status: 0, output_truncated?: true}} ->
            {:error, :remote_cli_output_too_large}

          {:ok, result} ->
            {:error, {:remote_cli_failed, result.exit_status, result.output_tail}}

          {:error, reason} ->
            {:error, reason}
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
        resource_key
      ],
      cd: workspace,
      env: %{
        "HOME" => workspace,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null"
      },
      timeout: @timeout,
      max_output_bytes: @diagnostic_bytes
    }
  end

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
