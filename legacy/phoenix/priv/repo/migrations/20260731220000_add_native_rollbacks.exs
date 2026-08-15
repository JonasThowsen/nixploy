defmodule Nixploy.Repo.Migrations.AddNativeRollbacks do
  use Ecto.Migration

  def change do
    alter table(:native_deployments) do
      add :operation_kind, :text, null: false, default: "deploy"

      add :rollback_of_id,
          references(:native_deployments, type: :binary_id, on_delete: :restrict)

      add :expected_image_id, :text
      add :expected_slot, :text
    end

    create index(:native_deployments, [:rollback_of_id, :inserted_at])

    create constraint(:native_deployments, :valid_native_operation_kind,
             check: "operation_kind IN ('deploy','rollback')"
           )

    create constraint(:native_deployments, :valid_native_rollback_identity,
             check: """
             (operation_kind = 'deploy' AND rollback_of_id IS NULL AND expected_image_id IS NULL AND expected_slot IS NULL)
             OR
             (operation_kind = 'rollback' AND rollback_of_id IS NOT NULL AND expected_image_id IS NOT NULL AND expected_slot IN ('blue','green'))
             """
           )
  end
end
