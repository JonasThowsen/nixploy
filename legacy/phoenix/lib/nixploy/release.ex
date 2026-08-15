defmodule Nixploy.Release do
  @moduledoc "Release-time database and initial operator tasks."

  @app :nixploy

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _migrated, _apps} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  def provision_operator(email, password) do
    with_repo(fn ->
      Nixploy.Accounts.provision_operator(%{email: email, password: password})
    end)
  end

  def provision_identity_operator(email) do
    with_repo(fn -> Nixploy.Accounts.provision_identity_operator(email) end)
  end

  defp with_repo(provision) do
    load_app()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(Nixploy.Repo, fn _repo ->
        case provision.() do
          {:ok, operator} ->
            operator.email

          {:error, changeset} ->
            raise "could not provision operator: #{inspect(changeset.errors)}"
        end
      end)
  end

  defp load_app do
    Application.load(@app)
  end
end
