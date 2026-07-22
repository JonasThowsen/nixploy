defmodule Nixploy.Operations.StatusWorker do
  @moduledoc "Refreshes one persisted service observation from worker-held credentials."

  use Oban.Worker,
    queue: :health_checks,
    max_attempts: 3,
    unique: [period: 60, fields: [:args], states: :incomplete]

  alias Nixploy.{Applications, Operations}
  alias Nixploy.Operations.StatusProbe

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"service_id" => service_id}}) do
    service = Applications.get_service!(service_id)

    case StatusProbe.observe(service) do
      {:ok, observed} ->
        case Operations.complete_status_refresh(service.id, observed) do
          {:ok, _observation} -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, reason} ->
        _ = Operations.fail_status_refresh(service.id, reason)
        {:error, inspect(reason)}
    end
  end
end
