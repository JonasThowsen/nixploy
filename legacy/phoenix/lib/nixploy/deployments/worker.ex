defmodule Nixploy.Deployments.Worker do
  @moduledoc "Runs an immutable deployment through the compatibility CLI and independent verification."

  use Oban.Worker,
    queue: :deployments,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:args], states: :incomplete]

  alias Nixploy.Deployments

  alias Nixploy.Deployments.{
    ConfigProbe,
    Deployment,
    LegacyExecutor,
    OutputBuffer,
    Source,
    Spec,
    TargetLease
  }

  alias Nixploy.Operations

  @cancellation_poll_ms :timer.seconds(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"deployment_id" => deployment_id}}) do
    deployment = Deployments.get_deployment!(deployment_id)

    cond do
      Deployment.terminal?(deployment) ->
        :ok

      deployment.cancellation_requested_at ->
        cancel(deployment)

      true ->
        with_target_lease(deployment)
    end
  rescue
    error ->
      _ = fail(deployment_id, {:worker_exception, Exception.message(error)})
      {:error, Exception.message(error)}
  end

  defp with_target_lease(deployment) do
    target_id = Spec.target_id(deployment.service_snapshot)

    case TargetLease.acquire(target_id, deployment.id) do
      {:ok, lease} ->
        try do
          run(deployment, lease)
        after
          TargetLease.release(lease)
        end

      {:error, :target_busy} ->
        {:snooze, 10}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp run(deployment, lease) do
    resuming? = deployment.state in [:building, :deploying, :verifying]

    try do
      do_run(deployment, lease, resuming?)
    after
      _ = Source.cleanup(deployment.id)
    end
  end

  defp do_run(deployment, lease, resuming?) do
    with {:ok, deployment} <- prepare(deployment),
         {:ok, workspace, commit} <- checkout(deployment, lease),
         {:ok, digest} <- preflight(deployment, workspace, lease),
         {:ok, deployment} <- record_commit(deployment, commit, digest),
         {:ok, observed} <- deploy_or_reconcile(deployment, workspace, lease, resuming?),
         {:ok, _deployment} <- checkpoint(deployment.id, lease),
         {:ok, deployment} <-
           transition_if_needed(
             deployment.id,
             :deploying,
             "Deployment command completed; reconciling target"
           ),
         {:ok, _deployment} <- checkpoint(deployment.id, lease),
         {:ok, deployment} <-
           transition_if_needed(deployment.id, :verifying, "Verifying observed target state"),
         {:ok, _observed} <- observed_or_verify(deployment, observed, lease),
         {:ok, _deployment} <- checkpoint(deployment.id, lease),
         {:ok, _deployment} <-
           transition_if_needed(
             deployment.id,
             :succeeded,
             "Deployment succeeded and was verified"
           ) do
      :ok
    else
      {:cancelled, deployment} -> cancel(deployment)
      {:error, :cancellation_requested} -> cancel(Deployments.get_deployment!(deployment.id))
      {:error, :target_lease_lost} -> {:error, "target lease lost"}
      {:error, reason} -> fail(deployment.id, reason)
    end
  end

  defp prepare(%{state: :queued} = deployment) do
    case Deployments.transition(deployment.id, :preparing, "Preparing immutable source checkout") do
      {:ok, _deployment, _event} -> {:ok, Deployments.get_deployment!(deployment.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare(deployment), do: {:ok, deployment}

  defp checkout(deployment, lease) do
    case Source.prepare(deployment, command_options(deployment.id, lease)) do
      {:ok, workspace, commit} -> {:ok, workspace, commit}
      {:error, :cancelled} -> stopped(deployment, lease)
      {:error, reason} -> {:error, reason}
    end
  end

  defp preflight(deployment, workspace, lease) do
    probe = Application.get_env(:nixploy, :deployment_config_probe, ConfigProbe)

    case probe.validate(deployment, workspace, command_options(deployment.id, lease)) do
      {:ok, digest} -> {:ok, digest}
      {:error, :cancelled} -> stopped(deployment, lease)
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_commit(%{state: :preparing} = deployment, commit, digest) do
    message =
      "Resolved #{deployment.requested_ref} to #{short_commit(commit)} and validated flake target"

    case Deployments.transition(deployment.id, :building, message, %{
           resolved_commit: commit,
           configuration_digest: digest
         }) do
      {:ok, _deployment, _event} -> {:ok, Deployments.get_deployment!(deployment.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_commit(deployment, commit, digest) do
    cond do
      deployment.resolved_commit != commit ->
        {:error, {:resolved_commit_mismatch, deployment.resolved_commit, commit}}

      deployment.configuration_digest != digest ->
        {:error, {:configuration_digest_mismatch, deployment.configuration_digest, digest}}

      true ->
        {:ok, deployment}
    end
  end

  defp deploy_or_reconcile(%{state: :building} = deployment, _workspace, lease, true) do
    case verify(deployment, lease) do
      {:ok, observed} ->
        _ =
          Deployments.record_event(
            deployment.id,
            "reconciliation",
            :info,
            "Recovered an already-applied healthy deployment after worker restart"
          )

        {:ok, observed}

      {:cancelled, _deployment} = cancelled ->
        cancelled

      {:error, :target_lease_lost} = error ->
        error

      {:error, reason} ->
        {:error, {:reconciliation_required, reason}}
    end
  end

  defp deploy_or_reconcile(%{state: :building} = deployment, workspace, lease, _resuming?) do
    execute(deployment, workspace, lease)
  end

  defp deploy_or_reconcile(%{state: state}, _workspace, _lease, _resuming?)
       when state in [:deploying, :verifying],
       do: {:ok, nil}

  defp execute(deployment, workspace, lease) do
    with :ok <- OutputBuffer.start(deployment.id),
         {:ok, _event} <-
           Deployments.record_event(
             deployment.id,
             "execution",
             :info,
             "Delegating the validated immutable deployment to the compatibility CLI"
           ) do
      # TODO(tracer): Select a native executor only for a persisted, verified
      # local-store input after one no-secret fixture proves Caddy rollback;
      # retain LegacyExecutor for existing Git-backed deployment recovery.
      result =
        LegacyExecutor.deploy(
          deployment,
          workspace,
          command_options(deployment.id, lease, &OutputBuffer.append(deployment.id, &1))
        )

      output_result = OutputBuffer.finish(deployment.id)

      cond do
        lease_lost?(deployment.id) -> {:error, :target_lease_lost}
        match?({:error, _reason}, output_result) -> output_result
        result == {:error, :cancelled} -> stopped(deployment, lease)
        true -> result |> normalize_execution_result()
      end
    end
  end

  defp normalize_execution_result({:ok, _result}), do: {:ok, nil}
  defp normalize_execution_result(error), do: error

  defp observed_or_verify(_deployment, observed, _lease) when is_map(observed),
    do: {:ok, observed}

  defp observed_or_verify(deployment, nil, lease), do: verify(deployment, lease)

  defp verify(deployment, lease) do
    probe =
      Application.get_env(:nixploy, :deployment_status_probe, Nixploy.Operations.StatusProbe)

    service = Spec.service(deployment.service_snapshot)

    result =
      if function_exported?(probe, :observe, 2),
        do: probe.observe(service, command_options(deployment.id, lease)),
        else: probe.observe(service)

    with {:ok, observed} <- result,
         {:ok, _observation} <-
           Operations.record_status_observation(deployment.service_id, observed),
         :ok <- validate_observation(deployment, observed) do
      {:ok, observed}
    else
      {:error, :cancelled} -> stopped(deployment, lease)
      error -> error
    end
  end

  defp validate_observation(deployment, observed) do
    cond do
      not commit_matches?(deployment.resolved_commit, observed.git_commit) ->
        {:error, {:verification_commit_mismatch, deployment.resolved_commit, observed.git_commit}}

      not running?(observed.active_container_state) ->
        {:error, {:verification_container_not_running, observed.active_container_state}}

      observed.health_status not in 200..299 ->
        {:error, {:verification_health_failed, observed.health_status, observed.health_error}}

      true ->
        :ok
    end
  end

  defp commit_matches?(expected, observed)
       when is_binary(expected) and is_binary(observed) and observed != "" do
    String.starts_with?(expected, observed) or String.starts_with?(observed, expected)
  end

  defp commit_matches?(_expected, _observed), do: false

  defp running?(state) when is_binary(state),
    do: state |> String.downcase() |> String.contains?("running")

  defp running?(_state), do: false

  defp transition_if_needed(deployment_id, next_state, message) do
    deployment = Deployments.get_deployment!(deployment_id)
    states = Deployment.states()
    current_index = Enum.find_index(states, &(&1 == deployment.state))
    next_index = Enum.find_index(states, &(&1 == next_state))

    cond do
      Deployment.terminal?(deployment) ->
        {:error, {:terminal, deployment.state}}

      current_index >= next_index ->
        {:ok, deployment}

      true ->
        case Deployments.transition(deployment.id, next_state, message) do
          {:ok, deployment, _event} -> {:ok, deployment}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp checkpoint(deployment_id, lease) do
    case TargetLease.maintain(lease) do
      {:error, :lease_lost} ->
        {:error, :target_lease_lost}

      :ok ->
        deployment = Deployments.get_deployment!(deployment_id)

        if deployment.cancellation_requested_at,
          do: {:cancelled, deployment},
          else: {:ok, deployment}
    end
  end

  defp command_options(deployment_id, lease, on_line \\ nil) do
    options = [
      cancelled?: fn -> stop_requested?(deployment_id, lease) end
    ]

    if is_function(on_line, 1), do: Keyword.put(options, :on_line, on_line), else: options
  end

  defp stop_requested?(deployment_id, lease) do
    case TargetLease.maintain(lease) do
      :ok ->
        cancellation_requested?(deployment_id) or OutputBuffer.failed?(deployment_id)

      {:error, :lease_lost} ->
        Process.put({__MODULE__, deployment_id, :lease_lost}, true)
        true
    end
  end

  defp cancellation_requested?(deployment_id) do
    key = {__MODULE__, deployment_id, :cancellation}
    now = System.monotonic_time(:millisecond)

    case Process.get(key) do
      {checked_at, requested?} when now - checked_at < @cancellation_poll_ms ->
        requested?

      _stale ->
        requested? = Deployments.cancellation_requested?(deployment_id)
        Process.put(key, {now, requested?})
        requested?
    end
  end

  defp stopped(deployment, lease) do
    if lease_lost?(deployment.id) do
      {:error, :target_lease_lost}
    else
      _ = TargetLease.maintain(lease)
      {:cancelled, Deployments.get_deployment!(deployment.id)}
    end
  end

  defp lease_lost?(deployment_id) do
    Process.delete({__MODULE__, deployment_id, :lease_lost}) == true
  end

  # TODO(tracer): Reconcile and persist identified remote side effects before
  # distinguishing clean cancellation from cancellation requiring intervention.
  defp cancel(deployment) do
    case Deployments.transition(
           deployment.id,
           :cancelled,
           "Local work stopped; refresh target status to reconcile remote side effects"
         ) do
      {:ok, _deployment, _event} ->
        :ok

      {:error, {:invalid_transition, state, :cancelled}}
      when state in [:succeeded, :failed, :cancelled] ->
        :ok

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp fail(deployment_id, reason) do
    deployment = Deployments.get_deployment!(deployment_id)

    if Deployment.terminal?(deployment) do
      :ok
    else
      message = failure_message(reason)

      case Deployments.transition(deployment.id, :failed, "Deployment failed: #{message}", %{
             failure: %{message: message}
           }) do
        {:ok, _deployment, _event} -> :ok
        {:error, transition_reason} -> {:error, inspect(transition_reason)}
      end
    end
  end

  defp failure_message({:executable_not_found, executable}),
    do: "executable not found: #{executable}"

  defp failure_message({:git_failed, status, output}),
    do: "Git exited with status #{status}: #{tail(output)}"

  defp failure_message({:nix_eval_failed, status, output}),
    do: "Nix evaluation exited with status #{status}: #{tail(output)}"

  defp failure_message({:configuration_mismatch, mismatches}),
    do: "flake target differs from registered service: #{inspect(mismatches)}"

  defp failure_message({:legacy_cli_failed, status, output}),
    do: "nixploy exited with status #{status}: #{tail(output)}"

  defp failure_message({:missing_success_marker, output}),
    do: "nixploy did not report successful completion: #{tail(output)}"

  defp failure_message({:invalid_repository_subdirectory, subdirectory}),
    do: "invalid repository subdirectory: #{subdirectory}"

  defp failure_message({:repository_subdirectory_not_found, subdirectory}),
    do: "repository subdirectory not found: #{subdirectory}"

  defp failure_message(:process_group_support_unavailable),
    do: "safe command execution requires bash and setsid"

  defp failure_message(:timeout), do: "command timed out"
  defp failure_message(reason), do: inspect(reason)

  defp tail(output) do
    output
    |> String.trim()
    |> String.slice(-1_000, 1_000)
  end

  defp short_commit(commit), do: String.slice(commit, 0, 12)
end
