defmodule Nixploy.Repo.Migrations.CreateRuntimeLogSnapshots do
  use Ecto.Migration

  def change do
    create table(:runtime_log_snapshots, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :application_key, :string, null: false

      add :native_deployment_id,
          references(:native_deployments, type: :uuid, on_delete: :delete_all),
          null: false

      add :request_id, :uuid, null: false
      add :status, :string, null: false, default: "pending"
      add :content, :text
      add :line_count, :integer
      add :truncated, :boolean, null: false, default: false
      add :failure, :map
      add :requested_at, :utc_datetime_usec, null: false
      add :fetched_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runtime_log_snapshots, [:application_key])
    create index(:runtime_log_snapshots, [:native_deployment_id])

    create constraint(:runtime_log_snapshots, :valid_runtime_log_status,
             check: "status IN ('pending', 'available', 'failed')"
           )

    create constraint(:runtime_log_snapshots, :valid_runtime_log_size,
             check:
               "(content IS NULL OR octet_length(content) <= 60000) AND (line_count IS NULL OR line_count BETWEEN 0 AND 200)"
           )
  end
end
