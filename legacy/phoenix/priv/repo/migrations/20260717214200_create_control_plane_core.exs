defmodule Nixploy.Repo.Migrations.CreateControlPlaneCore do
  use Ecto.Migration

  def change do
    create table(:repositories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :url, :text, null: false
      add :default_ref, :text, null: false, default: "main"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:repositories, [:name])

    create table(:targets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :host, :text, null: false
      add :ssh_port, :integer, null: false, default: 22
      add :ssh_user, :text, null: false, default: "root"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:targets, [:name])

    create table(:services, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :flake_output, :text, null: false, default: "docker"
      add :domain, :text
      add :health_path, :text, null: false, default: "/health"
      add :repository_id, references(:repositories, type: :binary_id), null: false
      add :target_id, references(:targets, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:services, [:target_id, :name])
    create unique_index(:services, [:domain], where: "domain IS NOT NULL")
    create index(:services, [:repository_id])

    create table(:deployments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :service_id, references(:services, type: :binary_id), null: false
      add :requested_ref, :text, null: false
      add :resolved_commit, :text
      add :state, :text, null: false, default: "queued"
      add :current_stage, :text, null: false, default: "queued"
      add :cancellation_requested_at, :utc_datetime
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :failure, :map

      timestamps(type: :utc_datetime)
    end

    create index(:deployments, [:service_id, :inserted_at])
    create index(:deployments, [:state])

    create constraint(:deployments, :valid_state,
             check:
               "state IN ('queued', 'preparing', 'building', 'deploying', 'verifying', 'succeeded', 'failed', 'cancelled')"
           )

    create table(:deployment_events) do
      add :deployment_id, references(:deployments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :level, :text, null: false, default: "info"
      add :stage, :text, null: false
      add :message, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:deployment_events, [:deployment_id, :id])

    create constraint(:deployment_events, :valid_level,
             check: "level IN ('debug', 'info', 'warning', 'error')"
           )
  end
end
