defmodule Nixploy.Repo.Migrations.CreateTaskOperations do
  use Ecto.Migration

  def change do
    create table(:task_operations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :native_deployment_id, references(:native_deployments, type: :uuid), null: false
      add :deployment_input_id, references(:deployment_inputs, type: :uuid), null: false
      add :requested_by_operator_id, references(:operators, type: :uuid), null: false
      add :task_name, :string, null: false
      add :description, :string, null: false
      add :confirmation, :string, null: false
      add :command_digest, :string, null: false
      add :resource_key, :string, null: false
      add :state, :string, null: false, default: "queued"
      add :output_tail, :text
      add :output_truncated, :boolean, null: false, default: false
      add :failure, :map
      add :cancellation_requested_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:task_operations, :valid_task_operation_state,
             check: "state IN ('queued','running','succeeded','failed','cancelled')"
           )

    create constraint(:task_operations, :valid_task_confirmation,
             check: "confirmation IN ('required','dangerous')"
           )

    create unique_index(:task_operations, [:resource_key],
             name: :one_active_task_per_resource,
             where: "state IN ('queued','running')"
           )

    create index(:task_operations, [:native_deployment_id, :inserted_at])
  end
end
