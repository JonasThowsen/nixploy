defmodule Nixploy.Repo.Migrations.BackfillDeploymentSnapshots do
  use Ecto.Migration

  def up do
    execute("""
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
    """)
  end

  def down, do: :ok
end
