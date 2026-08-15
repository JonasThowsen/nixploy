defmodule Nixploy.Repo.Migrations.CreateServiceLogSnapshots do
  use Ecto.Migration

  def change do
    create table(:service_log_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :text, null: false, default: "pending"
      add :target_identity, :text
      add :slot, :text
      add :container_name, :text
      add :content, :text
      add :line_count, :integer
      add :truncated, :boolean, null: false, default: false
      add :failure, :map
      add :requested_at, :utc_datetime, null: false
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:service_log_snapshots, [:service_id])

    create constraint(:service_log_snapshots, :valid_status,
             check: "status IN ('pending', 'available', 'failed')"
           )
  end
end
