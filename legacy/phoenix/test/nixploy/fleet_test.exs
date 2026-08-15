defmodule Nixploy.FleetTest do
  use Nixploy.DataCase, async: true

  alias Nixploy.Fleet
  alias Nixploy.Fleet.Target

  test "creates deployment targets" do
    assert {:ok, %Target{} = target} =
             Fleet.create_target(%{
               name: "production",
               host: "prod.example.com",
               ssh_user: "deploy"
             })

    assert target.ssh_port == 22
  end

  test "rejects SSH destinations that could be interpreted as command syntax" do
    assert {:error, changeset} =
             Fleet.create_target(%{
               name: "production",
               host: "example.com attacker",
               ssh_user: "deploy;whoami"
             })

    assert "must be a hostname or IP address" in errors_on(changeset).host
    assert "must be a valid SSH user" in errors_on(changeset).ssh_user
  end

  test "validates the SSH port" do
    assert {:error, changeset} =
             Fleet.create_target(%{
               name: "production",
               host: "prod.example.com",
               ssh_user: "deploy",
               ssh_port: 70_000
             })

    assert "must be less than or equal to 65535" in errors_on(changeset).ssh_port
  end
end
