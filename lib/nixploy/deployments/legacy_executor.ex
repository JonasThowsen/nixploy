defmodule Nixploy.Deployments.LegacyExecutor do
  @moduledoc "Temporary adapter that delegates a checked-out deployment to the existing nixploy CLI."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  # The current CLI reports operational failures in output without setting a
  # non-zero process exit status, so success requires its explicit final marker.
  @success_marker "Deployment completed successfully."

  def deploy(deployment, workspace, opts \\ []) do
    executable = Application.get_env(:nixploy, :legacy_nixploy_executable, "nixploy")
    timeout = Application.get_env(:nixploy, :legacy_deployment_timeout, :timer.hours(1))

    command = %Command{
      executable: executable,
      args: ["deploy", "--target", deployment.service.target.name],
      cd: workspace,
      timeout: timeout
    }

    case Execution.run(command, opts) do
      {:ok, %{exit_status: 0, output_tail: output_tail} = result} ->
        if String.contains?(output_tail, @success_marker) do
          {:ok, result}
        else
          {:error, {:missing_success_marker, output_tail}}
        end

      {:ok, result} ->
        {:error, {:legacy_cli_failed, result.exit_status, result.output_tail}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
