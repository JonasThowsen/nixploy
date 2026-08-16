defmodule Nixploy.Repo.Migrations.CreateServiceObservations do
  use Ecto.Migration

  def change do
    create table(:service_observations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :text, null: false, default: "pending"
      add :target_identity, :text
      add :active_slot, :text
      add :inactive_slot, :text
      add :active_container, :text
      add :active_container_state, :text
      add :inactive_container, :text
      add :inactive_container_state, :text
      add :image, :text
      add :git_commit, :text
      add :deployed_at, :utc_datetime_usec
      add :caddy_route, :text
      add :upstream, :text
      add :health_url, :text
      add :health_status, :integer
      add :health_error, :text
      add :failure, :map
      add :requested_at, :utc_datetime, null: false
      add :refreshed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:service_observations, [:service_id])

    create constraint(:service_observations, :valid_status,
             check: "status IN ('pending', 'available', 'failed')"
           )
  end
end
