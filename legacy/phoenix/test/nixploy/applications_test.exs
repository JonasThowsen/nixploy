defmodule Nixploy.ApplicationsTest do
  use Nixploy.DataCase, async: true

  alias Nixploy.Applications
  alias Nixploy.Applications.{Repository, Service}
  alias Nixploy.Fixtures

  test "creates repositories with a stable default ref" do
    assert {:ok, %Repository{} = repository} =
             Applications.create_repository(%{
               name: "example",
               url: "https://example.com/example.git"
             })

    assert repository.default_ref == "main"
    assert repository.subdirectory == "."
  end

  test "accepts safe flake subdirectories and rejects traversal" do
    assert {:ok, repository} =
             Applications.create_repository(%{
               name: "monorepo",
               url: "https://example.com/monorepo.git",
               subdirectory: "apps/web"
             })

    assert repository.subdirectory == "apps/web"

    assert {:error, changeset} =
             Applications.create_repository(%{
               name: "unsafe-monorepo",
               url: "https://example.com/monorepo.git",
               subdirectory: "../outside"
             })

    assert "must be a relative path without parent traversal" in errors_on(changeset).subdirectory
  end

  test "repository names are unique" do
    repository = Fixtures.repository_fixture()

    assert {:error, changeset} =
             Applications.create_repository(%{
               name: repository.name,
               url: "https://example.com/other.git"
             })

    assert "has already been taken" in errors_on(changeset).name
  end

  test "creates a service attached to a repository and target" do
    repository = Fixtures.repository_fixture()
    target = Fixtures.target_fixture()

    assert {:ok, %Service{} = service} =
             Applications.create_service(%{
               name: "web",
               repository_id: repository.id,
               target_id: target.id,
               flake_output: "packages.x86_64-linux.oci",
               domain: "app.example.com",
               health_path: "/health"
             })

    assert service.domain == "app.example.com"
  end

  test "requires service domains without schemes or paths" do
    repository = Fixtures.repository_fixture()
    target = Fixtures.target_fixture()

    assert {:error, changeset} =
             Applications.create_service(%{
               name: "web",
               repository_id: repository.id,
               target_id: target.id,
               domain: "https://app.example.com/path"
             })

    assert "must be a hostname without a scheme or path" in errors_on(changeset).domain
  end

  test "requires health paths to start with a slash" do
    repository = Fixtures.repository_fixture()
    target = Fixtures.target_fixture()

    assert {:error, changeset} =
             Applications.create_service(%{
               name: "web",
               repository_id: repository.id,
               target_id: target.id,
               health_path: "health"
             })

    assert "must start with /" in errors_on(changeset).health_path
  end
end
