defmodule Nixploy.Fleet do
  @moduledoc "Deployment targets managed by nixploy workers."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Fleet.Target
  alias Nixploy.{Audit, Repo}

  def list_targets do
    Target
    |> order_by([target], asc: target.name)
    |> Repo.all()
  end

  def get_target!(id), do: Repo.get!(Target, id)

  def create_target(attrs \\ %{}, opts \\ []) do
    operator = Keyword.get(opts, :operator)

    Multi.new()
    |> Multi.insert(:resource, Target.changeset(%Target{}, attrs))
    |> Multi.insert(:audit, fn %{resource: target} ->
      Audit.changeset(operator, :created, :target, target.id)
    end)
    |> Repo.transaction()
    |> unwrap_resource()
  end

  def update_target(%Target{} = target, attrs, opts \\ []) do
    operator = Keyword.get(opts, :operator)

    Multi.new()
    |> Multi.update(:resource, Target.changeset(target, attrs))
    |> Multi.insert(:audit, fn %{resource: updated} ->
      Audit.changeset(operator, :updated, :target, updated.id)
    end)
    |> Repo.transaction()
    |> unwrap_resource()
  end

  def change_target(%Target{} = target, attrs \\ %{}) do
    Target.changeset(target, attrs)
  end

  defp unwrap_resource({:ok, %{resource: resource}}), do: {:ok, resource}
  defp unwrap_resource({:error, _operation, reason, _changes}), do: {:error, reason}
end
