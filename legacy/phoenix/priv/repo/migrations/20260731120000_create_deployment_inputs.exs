defmodule Nixploy.Repo.Migrations.CreateDeploymentInputs do
  use Ecto.Migration

  def change do
    create table(:deployment_inputs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :input_kind, :text, null: false
      add :store_path, :text, null: false
      add :nar_hash, :text
      add :selected_target, :text
      add :derived_snapshot, :map, null: false, default: %{}
      add :configuration_digest, :text
      add :state, :text, null: false, default: "staging"
      add :failure, :map

      add :requested_by_operator_id,
          references(:operators, type: :binary_id, on_delete: :restrict),
          null: false

      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:deployment_inputs, [:inserted_at])
    create index(:deployment_inputs, [:requested_by_operator_id, :inserted_at])
    create index(:deployment_inputs, [:store_path, :nar_hash])

    create constraint(:deployment_inputs, :valid_input_kind,
             check: "input_kind IN ('local_store')"
           )

    create constraint(:deployment_inputs, :valid_deployment_input_state,
             check: "state IN ('staging', 'staged', 'failed')"
           )
  end
end
