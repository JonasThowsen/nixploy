defmodule Nixploy.Repo.Migrations.CreateNativeTargetLeases do
  use Ecto.Migration

  def change do
    create table(:native_target_leases, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :resource_key, :string, null: false
      add :owner_id, :uuid, null: false
      add :fencing_token, :bigint, null: false
      add :heartbeat_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :native_deployment_id,
          references(:native_deployments, type: :uuid, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:native_target_leases, [:resource_key])
    create index(:native_target_leases, [:expires_at])

    alter table(:native_deployments) do
      add :fencing_token, :bigint
      add :retry_of_id, references(:native_deployments, type: :uuid, on_delete: :nilify_all)
    end

    create index(:native_deployments, [:retry_of_id])

    create constraint(:native_deployments, :valid_native_fencing_token,
             check: "fencing_token IS NULL OR fencing_token > 0"
           )
  end
end
