defmodule Nixploy.Repo.Migrations.CreateOperators do
  use Ecto.Migration

  def change do
    create table(:operators, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :text, null: false
      add :password_hash, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operators, [:email])
  end
end
