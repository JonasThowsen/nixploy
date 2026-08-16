defmodule Nixploy.Deployments.Spec do
  @moduledoc "Immutable service inputs captured when a deployment is requested."

  alias Nixploy.Applications.{Repository, Service}
  alias Nixploy.Fleet.Target

  def snapshot(%Service{} = service) do
    %{
      "service" => %{
        "id" => service.id,
        "name" => service.name,
        "flake_output" => service.flake_output,
        "domain" => service.domain,
        "health_path" => service.health_path
      },
      "repository" => %{
        "id" => service.repository.id,
        "name" => service.repository.name,
        "url" => service.repository.url,
        "subdirectory" => service.repository.subdirectory
      },
      "target" => %{
        "id" => service.target.id,
        "name" => service.target.name,
        "host" => service.target.host,
        "ssh_port" => service.target.ssh_port,
        "ssh_user" => service.target.ssh_user
      }
    }
  end

  def service(%{"service" => service, "repository" => repository, "target" => target}) do
    %Service{
      id: service["id"],
      name: service["name"],
      flake_output: service["flake_output"],
      domain: service["domain"],
      health_path: service["health_path"],
      repository: struct(Repository, atomize(repository)),
      target: struct(Target, atomize(target))
    }
  end

  def target_id(snapshot), do: get_in(snapshot, ["target", "id"])
  def target_name(snapshot), do: get_in(snapshot, ["target", "name"])
  def repository_url(snapshot), do: get_in(snapshot, ["repository", "url"])
  def repository_subdirectory(snapshot), do: get_in(snapshot, ["repository", "subdirectory"])

  defp atomize(values) do
    Map.new(values, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end
end
