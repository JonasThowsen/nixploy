defmodule Nixploy.Deployments.LegacyExecutor do
  @moduledoc "Temporary adapter that delegates a checked-out deployment to the existing nixploy CLI."

  alias Nixploy.Deployments.Spec
  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  def deploy(deployment, workspace, opts \\ []) do
    executable = Application.get_env(:nixploy, :legacy_nixploy_executable, "nixploy")
    timeout = Application.get_env(:nixploy, :legacy_deployment_timeout, :timer.hours(1))

    # TODO(tracer): Replace the flake-target-name compatibility contract with
    # native adapters consuming the normalized service and target records.
    command = %Command{
      executable: executable,
      args: ["deploy", "--target", Spec.target_name(deployment.service_snapshot)],
      cd: workspace,
      timeout: timeout
    }

    case Execution.run(command, opts) do
      {:ok, %{exit_status: 0} = result} ->
        {:ok, result}

      {:ok, result} ->
        {:error, {:legacy_cli_failed, result.exit_status, result.output_tail}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
