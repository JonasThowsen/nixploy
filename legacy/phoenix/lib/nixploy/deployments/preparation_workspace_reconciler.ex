defmodule Nixploy.Deployments.PreparationWorkspaceReconciler do
  @moduledoc "Removes abandoned private preparation directories before Oban starts workers."

  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> reconcile(opts) end]},
      restart: :temporary
    }
  end

  defp reconcile(opts) do
    root = Keyword.get(opts, :root)

    result =
      if is_binary(root),
        do: Nixploy.Deployments.MainSource.cleanup_abandoned(root),
        else: Nixploy.Deployments.MainSource.cleanup_abandoned()

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("preparation workspace reconciliation failed: #{inspect(reason)}")
    end
  end
end
