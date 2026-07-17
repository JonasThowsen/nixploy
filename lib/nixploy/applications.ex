defmodule Nixploy.Applications do
  @moduledoc "Git repositories and deployable services."

  import Ecto.Query, warn: false

  alias Nixploy.Applications.{Repository, Service}
  alias Nixploy.Repo

  def list_repositories do
    Repository
    |> order_by([repository], asc: repository.name)
    |> Repo.all()
  end

  def get_repository!(id), do: Repo.get!(Repository, id)

  def create_repository(attrs \\ %{}) do
    %Repository{}
    |> Repository.changeset(attrs)
    |> Repo.insert()
  end

  def change_repository(%Repository{} = repository, attrs \\ %{}) do
    Repository.changeset(repository, attrs)
  end

  def list_services do
    Service
    |> order_by([service], asc: service.name)
    |> preload([:repository, :target])
    |> Repo.all()
  end

  def get_service!(id) do
    Service
    |> Repo.get!(id)
    |> Repo.preload([:repository, :target])
  end

  def create_service(attrs \\ %{}) do
    %Service{}
    |> Service.changeset(attrs)
    |> Repo.insert()
  end

  def change_service(%Service{} = service, attrs \\ %{}) do
    Service.changeset(service, attrs)
  end
end
