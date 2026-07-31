defmodule Nixploy.Repo.Migrations.CreateNativeDeployments do
  use Ecto.Migration

  @active_states ~w(queued preparing building loading preparing_slot starting health_checking switching verifying)

  def change do
    create table(:native_deployments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :deployment_input_id,
          references(:deployment_inputs, type: :binary_id, on_delete: :restrict),
          null: false

      add :requested_by_operator_id,
          references(:operators, type: :binary_id, on_delete: :restrict),
          null: false

      add :project, :text, null: false
      add :target, :text, null: false
      add :state, :text, null: false, default: "queued"
      add :current_stage, :text, null: false, default: "queued"
      add :resource_prefix, :text
      add :previous_upstream, :text
      add :selected_slot, :text
      add :selected_port, :integer
      add :image_store_path, :text
      add :image_reference, :text
      add :image_id, :text
      add :container_name, :text
      add :container_id, :text
      add :verified_upstream, :text
      add :failure, :map
      add :cancellation_requested_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:native_deployments, [:deployment_input_id, :inserted_at])
    create index(:native_deployments, [:requested_by_operator_id, :inserted_at])

    create unique_index(:native_deployments, [:project, :target],
             name: :one_active_native_deployment_per_target,
             where: "state IN (#{Enum.map_join(@active_states, ",", &"'#{&1}'")})"
           )

    create constraint(:native_deployments, :valid_native_deployment_state,
             check:
               "state IN ('queued','preparing','building','loading','preparing_slot','starting','health_checking','switching','verifying','succeeded','failed','cancelled')"
           )

    create constraint(:native_deployments, :valid_native_slot,
             check: "selected_slot IS NULL OR selected_slot IN ('blue','green')"
           )

    create table(:native_deployment_events) do
      add :native_deployment_id,
          references(:native_deployments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :stage, :text, null: false
      add :level, :text, null: false, default: "info"
      add :message, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:native_deployment_events, [:native_deployment_id, :id])

    create constraint(:native_deployment_events, :valid_native_event_level,
             check: "level IN ('info','warning','error')"
           )
  end
end
