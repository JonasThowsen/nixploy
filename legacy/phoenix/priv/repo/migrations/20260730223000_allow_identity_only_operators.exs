defmodule Nixploy.Repo.Migrations.AllowIdentityOnlyOperators do
  use Ecto.Migration

  def change do
    alter table(:operators) do
      modify :password_hash, :text, null: true, from: {:text, null: false}
    end
  end
end
