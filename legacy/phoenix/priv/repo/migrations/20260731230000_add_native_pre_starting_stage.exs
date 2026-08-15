defmodule Nixploy.Repo.Migrations.AddNativePreStartingStage do
  use Ecto.Migration

  @active_states ~w(queued preparing building loading preparing_slot pre_starting starting health_checking switching verifying)

  def up do
    drop constraint(:native_deployments, :valid_native_deployment_state)

    create constraint(:native_deployments, :valid_native_deployment_state,
             check:
               "state IN ('queued','preparing','building','loading','preparing_slot','pre_starting','starting','health_checking','switching','verifying','succeeded','failed','cancelled')"
           )

    drop_if_exists index(:native_deployments, [:project, :target],
                     name: :one_active_native_deployment_per_target
                   )

    create unique_index(:native_deployments, [:project, :target],
             name: :one_active_native_deployment_per_target,
             where: "state IN (#{Enum.map_join(@active_states, ",", &"'#{&1}'")})"
           )
  end

  def down do
    execute("""
    UPDATE native_deployments
    SET state = 'failed',
        current_stage = 'failed',
        failure = '{"code":"migration_downgrade","message":"pre-start operation interrupted by schema downgrade"}'::jsonb,
        finished_at = COALESCE(finished_at, NOW())
    WHERE state = 'pre_starting' OR current_stage = 'pre_starting'
    """)

    drop_if_exists index(:native_deployments, [:project, :target],
                     name: :one_active_native_deployment_per_target
                   )

    create unique_index(:native_deployments, [:project, :target],
             name: :one_active_native_deployment_per_target,
             where:
               "state IN ('queued','preparing','building','loading','preparing_slot','starting','health_checking','switching','verifying')"
           )

    drop constraint(:native_deployments, :valid_native_deployment_state)

    create constraint(:native_deployments, :valid_native_deployment_state,
             check:
               "state IN ('queued','preparing','building','loading','preparing_slot','starting','health_checking','switching','verifying','succeeded','failed','cancelled')"
           )
  end
end
