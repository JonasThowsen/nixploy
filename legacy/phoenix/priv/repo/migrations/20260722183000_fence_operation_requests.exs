defmodule Nixploy.Repo.Migrations.FenceOperationRequests do
  use Ecto.Migration

  def change do
    alter table(:service_observations) do
      add :request_id, :uuid
    end

    alter table(:service_log_snapshots) do
      add :request_id, :uuid
    end

    create index(:service_observations, [:service_id, :request_id])
    create index(:service_log_snapshots, [:service_id, :request_id])
  end
end
