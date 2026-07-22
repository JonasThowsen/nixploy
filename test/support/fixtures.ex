defmodule Nixploy.Fixtures do
  alias Nixploy.{Accounts, Applications, Fleet}

  def operator_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs = Map.new(attrs)

    operator_attrs = %{
      email: Map.get(attrs, :email, "operator-#{unique}@example.com"),
      password: Map.get(attrs, :password, "correct horse battery staple")
    }

    {:ok, operator} = Accounts.provision_operator(operator_attrs)
    operator
  end

  def repository_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          name: "repository-#{unique}",
          url: "https://example.com/repository-#{unique}.git",
          default_ref: "main",
          subdirectory: "."
        },
        Map.new(attrs)
      )

    {:ok, repository} = Applications.create_repository(attrs)
    repository
  end

  def target_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          name: "target-#{unique}",
          host: "target-#{unique}.example.com",
          ssh_port: 22,
          ssh_user: "deploy"
        },
        Map.new(attrs)
      )

    {:ok, target} = Fleet.create_target(attrs)
    target
  end

  def service_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    repository = Map.get_lazy(attrs, :repository, &repository_fixture/0)
    target = Map.get_lazy(attrs, :target, &target_fixture/0)
    unique = System.unique_integer([:positive])

    service_attrs =
      attrs
      |> Map.new()
      |> Map.drop([:repository, :target])
      |> Map.merge(%{
        name: Map.get(attrs, :name, "service-#{unique}"),
        flake_output: Map.get(attrs, :flake_output, "docker"),
        domain: Map.get(attrs, :domain),
        health_path: Map.get(attrs, :health_path, "/health"),
        repository_id: repository.id,
        target_id: target.id
      })

    {:ok, service} = Applications.create_service(service_attrs)
    service
  end

  def deployment_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    service = Map.get_lazy(attrs, :service, &service_fixture/0)

    deployment_attrs =
      attrs
      |> Map.new()
      |> Map.drop([:service])
      |> Map.put_new(:service_id, service.id)
      |> Map.put_new(:requested_ref, "main")

    {:ok, deployment, _event} = Nixploy.Deployments.create_deployment(deployment_attrs)
    deployment
  end
end
