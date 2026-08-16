defmodule Nixploy.Repo.Migrations.AddCiReleaseRegistration do
  use Ecto.Migration

  def change do
    alter table(:deployment_inputs) do
      add :registration_channel, :string, null: false, default: "operator"
      add :source_repository, :string
      add :source_revision, :string
    end

    create constraint(:deployment_inputs, :valid_registration_channel,
             check: "registration_channel IN ('operator', 'ci')"
           )

    create constraint(:deployment_inputs, :valid_ci_release_provenance,
             check:
               "registration_channel <> 'ci' OR (source_repository IS NOT NULL AND source_revision IS NOT NULL)"
           )

    create unique_index(:deployment_inputs, [:store_path, :selected_target],
             where: "state = 'staged'",
             name: :deployment_inputs_unique_staged_release
           )
  end
end
