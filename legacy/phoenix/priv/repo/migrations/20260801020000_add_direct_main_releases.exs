defmodule Nixploy.Repo.Migrations.AddDirectMainReleases do
  use Ecto.Migration

  def up do
    drop constraint(:deployment_inputs, :valid_input_kind)

    alter table(:deployment_inputs) do
      modify :store_path, :text, null: true, from: {:text, null: false}
      add :application_key, :string
      add :source_ref, :string
      add :repository_subdirectory, :string
      add :commit_subject, :string
      add :commit_timestamp, :utc_datetime_usec
      add :requested_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec
    end

    create constraint(:deployment_inputs, :valid_input_kind,
             check: "input_kind IN ('local_store', 'git_main')"
           )

    create constraint(:deployment_inputs, :valid_direct_main_provenance,
             check:
               "input_kind <> 'git_main' OR (application_key IS NOT NULL AND source_repository IS NOT NULL AND source_ref = 'refs/heads/main' AND selected_target IS NOT NULL)"
           )

    create index(:deployment_inputs, [:application_key, :inserted_at])

    create unique_index(
             :deployment_inputs,
             [:application_key, :source_revision, :selected_target, :configuration_digest],
             where: "input_kind = 'git_main' AND state = 'staged'",
             name: :deployment_inputs_unique_direct_main_release
           )

    create table(:deployment_input_events, primary_key: false) do
      add :id, :bigserial, primary_key: true

      add :deployment_input_id,
          references(:deployment_inputs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :stage, :string, null: false
      add :level, :string, null: false, default: "info"
      add :message, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:deployment_input_events, [:deployment_input_id, :id])
  end

  def down do
    drop table(:deployment_input_events)
    drop index(:deployment_inputs, [:application_key, :inserted_at])
    drop index(:deployment_inputs, name: :deployment_inputs_unique_direct_main_release)
    drop constraint(:deployment_inputs, :valid_direct_main_provenance)
    drop constraint(:deployment_inputs, :valid_input_kind)

    alter table(:deployment_inputs) do
      remove :resolved_at
      remove :requested_at
      remove :commit_timestamp
      remove :commit_subject
      remove :repository_subdirectory
      remove :source_ref
      remove :application_key
      modify :store_path, :text, null: false, from: {:text, null: true}
    end

    create constraint(:deployment_inputs, :valid_input_kind,
             check: "input_kind IN ('local_store')"
           )
  end
end
