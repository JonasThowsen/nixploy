defmodule Nixploy.Repo.Migrations.CreateWorkerHeartbeats do
  use Ecto.Migration

  def change do
    create table(:worker_heartbeats, primary_key: false) do
      add :runtime_id, :uuid, primary_key: true
      add :hostname, :string, null: false
      add :os_pid, :integer, null: false
      add :capabilities, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create index(:worker_heartbeats, [:last_seen_at])
  end
end
