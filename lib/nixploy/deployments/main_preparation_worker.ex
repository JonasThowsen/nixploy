defmodule Nixploy.Deployments.MainPreparationWorker do
  @moduledoc "Prepares one trusted application's freshly resolved main commit."

  use Oban.Worker,
    queue: :deployments,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:args], states: :incomplete]

  alias Nixploy.{Deployments, ManagedApplications}
  alias Nixploy.Deployments.DeploymentInput

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"deployment_input_id" => id}}) do
    input = Deployments.get_deployment_input!(id)

    cond do
      input.state in [:staged, :failed] -> :ok
      input.input_kind != :git_main -> {:discard, :unsupported_input_kind}
      true -> prepare(input)
    end
  rescue
    error ->
      _ = Deployments.fail_main_preparation(id, {:worker_exception, Exception.message(error)})
      {:error, Exception.message(error)}
  end

  defp prepare(%DeploymentInput{} = input) do
    source = Application.get_env(:nixploy, :main_source, Nixploy.Deployments.MainSource)

    with {:ok, application} <- ManagedApplications.fetch(input.application_key),
         :ok <- progress(input.id, "resolving", "Resolving exact refs/heads/main"),
         {:ok, oid} <- source.resolve_main(application, source_opts(input.id)),
         {:ok, resolved} <- Deployments.resolve_main_input(input.id, oid),
         :ok <- progress(input.id, "fetching", "Fetching the persisted Git object"),
         {:ok, result} <- source.materialize(resolved, application, source_opts(input.id)),
         {:ok, _staged} <- Deployments.complete_main_preparation(input.id, result) do
      :ok
    else
      {:error, %DeploymentInput{state: :failed}} -> :ok
      {:error, reason} -> fail(input.id, reason)
    end
  end

  defp source_opts(id) do
    [cancelled?: fn -> cancelled?(id) end]
  end

  # Preparation cancellation persistence is completed in Slice 5. Until then
  # this exact boundary remains false and no mutation follows preparation.
  defp cancelled?(_id), do: false

  defp progress(id, stage, message) do
    case Deployments.record_input_event(id, stage, message) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail(id, reason) do
    case Deployments.fail_main_preparation(id, reason) do
      {:ok, _input} -> :ok
      {:error, transition_reason} -> {:error, inspect(transition_reason)}
    end
  end
end
