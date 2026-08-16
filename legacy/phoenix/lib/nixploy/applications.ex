defmodule Nixploy.Applications do
  @moduledoc "Git repositories and deployable services."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Nixploy.Applications.{Repository, Service}
  alias Nixploy.{Audit, Repo}

  def list_repositories do
    Repository
    |> order_by([repository], asc: repository.name)
    |> Repo.all()
  end

  def get_repository!(id), do: Repo.get!(Repository, id)

  def create_repository(attrs \\ %{}, opts \\ []) do
    operator = Keyword.get(opts, :operator)

    Multi.new()
    |> Multi.insert(:resource, Repository.changeset(%Repository{}, attrs))
    |> Multi.insert(:audit, fn %{resource: repository} ->
      Audit.changeset(operator, :created, :repository, repository.id)
    end)
    |> Repo.transaction()
    |> unwrap_resource()
  end

  def update_repository(%Repository{} = repository, attrs, opts \\ []) do
    operator = Keyword.get(opts, :operator)

    Multi.new()
    |> Multi.update(:resource, Repository.changeset(repository, attrs))
    |> Multi.insert(:audit, fn %{resource: updated} ->
      Audit.changeset(operator, :updated, :repository, updated.id)
    end)
    |> Repo.transaction()
    |> unwrap_resource()
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

  def create_service(attrs \\ %{}, opts \\ []) do
    operator = Keyword.get(opts, :operator)

    Multi.new()
    |> Multi.insert(:resource, Service.changeset(%Service{}, attrs))
    |> Multi.insert(:audit, fn %{resource: service} ->
      Audit.changeset(operator, :created, :service, service.id)
    end)
    |> Repo.transaction()
    |> unwrap_resource()
  end

  def update_service(%Service{} = service, attrs, opts \\ []) do
    operator = Keyword.get(opts, :operator)

    Multi.new()
    |> Multi.update(:resource, Service.changeset(service, attrs))
    |> Multi.insert(:audit, fn %{resource: updated} ->
      Audit.changeset(operator, :updated, :service, updated.id)
    end)
    |> Repo.transaction()
    |> unwrap_resource()
  end

  def change_service(%Service{} = service, attrs \\ %{}) do
    Service.changeset(service, attrs)
  end

  defp unwrap_resource({:ok, %{resource: resource}}), do: {:ok, resource}
  defp unwrap_resource({:error, _operation, reason, _changes}), do: {:error, reason}
end
