defmodule Nixploy.Repo.Migrations.AddRepositorySubdirectory do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :subdirectory, :text, null: false, default: "."
    end
  end
end
