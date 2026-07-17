defmodule Nixploy.Fleet do
  @moduledoc "Deployment targets managed by nixploy workers."

  import Ecto.Query, warn: false

  alias Nixploy.Fleet.Target
  alias Nixploy.Repo

  def list_targets do
    Target
    |> order_by([target], asc: target.name)
    |> Repo.all()
  end

  def get_target!(id), do: Repo.get!(Target, id)

  def create_target(attrs \\ %{}) do
    %Target{}
    |> Target.changeset(attrs)
    |> Repo.insert()
  end

  def change_target(%Target{} = target, attrs \\ %{}) do
    Target.changeset(target, attrs)
  end
end
