defmodule Nixploy.Repo.Migrations.HardenDeploymentMvp do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :service_snapshot, :map, null: false, default: %{}
      add :configuration_digest, :text

      add :requested_by_operator_id,
          references(:operators, type: :binary_id, on_delete: :nilify_all)

      add :cancellation_requested_by_operator_id,
          references(:operators, type: :binary_id, on_delete: :nilify_all)

      add :retry_of_deployment_id,
          references(:deployments, type: :binary_id, on_delete: :nilify_all)
    end

    execute(
      """
      UPDATE deployments AS deployment
      SET service_snapshot = jsonb_build_object(
        'service', jsonb_build_object(
          'id', service.id,
          'name', service.name,
          'flake_output', service.flake_output,
          'domain', service.domain,
          'health_path', service.health_path
        ),
        'repository', jsonb_build_object(
          'id', repository.id,
          'name', repository.name,
          'url', repository.url,
          'subdirectory', repository.subdirectory
        ),
        'target', jsonb_build_object(
          'id', target.id,
          'name', target.name,
          'host', target.host,
          'ssh_port', target.ssh_port,
          'ssh_user', target.ssh_user
        )
      )
      FROM services AS service
      JOIN repositories AS repository ON repository.id = service.repository_id
      JOIN targets AS target ON target.id = service.target_id
      WHERE deployment.service_id = service.id
        AND deployment.service_snapshot = '{}'::jsonb
      """,
      "SELECT 1"
    )

    create index(:deployments, [:requested_by_operator_id])
    create index(:deployments, [:retry_of_deployment_id])

    create table(:deployment_outputs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :deployment_id, references(:deployments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :content, :text, null: false, default: ""
      add :line_count, :bigint, null: false, default: 0
      add :truncated, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:deployment_outputs, [:deployment_id])

    create table(:target_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :target_id, references(:targets, type: :binary_id, on_delete: :delete_all), null: false

      add :deployment_id, references(:deployments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :owner_id, :binary_id, null: false
      add :fencing_token, :bigint, null: false
      add :heartbeat_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create unique_index(:target_leases, [:target_id])
    create index(:target_leases, [:deployment_id])

    create table(:audit_events) do
      add :operator_id, references(:operators, type: :binary_id, on_delete: :nilify_all)
      add :action, :text, null: false
      add :resource_type, :text, null: false
      add :resource_id, :text, null: false
      add :outcome, :text, null: false, default: "succeeded"
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:audit_events, [:occurred_at])
    create index(:audit_events, [:operator_id, :occurred_at])
    create index(:audit_events, [:resource_type, :resource_id])
  end
end
