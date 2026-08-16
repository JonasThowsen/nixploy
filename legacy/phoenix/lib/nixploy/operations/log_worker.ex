defmodule Nixploy.Operations.LogWorker do
  @moduledoc "Refreshes active service state and captures a bounded container log snapshot."

  use Oban.Worker,
    queue: :logs,
    max_attempts: 3,
    unique: [period: 60, fields: [:args], states: :incomplete]

  alias Nixploy.{Applications, Operations}
  alias Nixploy.Operations.{LogProbe, StatusProbe}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "service_id" => service_id,
          "request_id" => request_id,
          "status_request_id" => status_request_id
        }
      }) do
    service = Applications.get_service!(service_id)

    case StatusProbe.observe(service) do
      {:ok, observed} ->
        fetch_logs(service, status_request_id, request_id, observed)

      {:error, reason} ->
        _ = Operations.fail_status_refresh(service.id, status_request_id, reason)
        fail_logs(service.id, request_id, reason)
    end
  end

  defp fetch_logs(service, status_request_id, request_id, observed) do
    with {:ok, _observation} <-
           Operations.complete_status_refresh(service.id, status_request_id, observed),
         {:ok, logs} <- LogProbe.fetch(service, observed),
         {:ok, _snapshot} <- Operations.complete_log_snapshot(service.id, request_id, logs) do
      :ok
    else
      {:error, reason} -> fail_logs(service.id, request_id, reason)
    end
  end

  defp fail_logs(service_id, request_id, reason) do
    _ = Operations.fail_log_snapshot(service_id, request_id, reason)
    {:error, inspect(reason)}
  end
end
