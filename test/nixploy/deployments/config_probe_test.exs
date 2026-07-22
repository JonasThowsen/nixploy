defmodule Nixploy.Deployments.ConfigProbeTest do
  use Nixploy.DataCase, async: true

  alias Nixploy.Deployments.ConfigProbe
  alias Nixploy.Fixtures

  test "accepts an evaluated flake target matching the immutable service snapshot" do
    deployment = Fixtures.deployment_fixture()
    snapshot = deployment.service_snapshot
    target_name = snapshot["target"]["name"]

    config = %{
      "__schema" => "v0.2",
      "targets" => %{
        target_name => %{
          "image" => snapshot["service"]["flake_output"],
          "ip" => snapshot["target"]["host"],
          "port" => snapshot["target"]["ssh_port"],
          "user" => snapshot["target"]["ssh_user"],
          "web" => %{
            "domain" => snapshot["service"]["domain"],
            "healthPath" => snapshot["service"]["health_path"]
          }
        }
      }
    }

    assert {:ok, digest} = ConfigProbe.validate_config(config, snapshot)
    assert byte_size(digest) == 64
  end

  test "rejects a flake target pointing at a different host" do
    deployment = Fixtures.deployment_fixture()
    snapshot = deployment.service_snapshot
    target_name = snapshot["target"]["name"]

    config = %{
      "__schema" => "v0.2",
      "targets" => %{
        target_name => %{
          "image" => snapshot["service"]["flake_output"],
          "ip" => "different.example.com",
          "port" => snapshot["target"]["ssh_port"],
          "user" => snapshot["target"]["ssh_user"],
          "web" => %{
            "domain" => snapshot["service"]["domain"],
            "healthPath" => snapshot["service"]["health_path"]
          }
        }
      }
    }

    assert {:error, {:configuration_mismatch, mismatches}} =
             ConfigProbe.validate_config(config, snapshot)

    assert %{field: "ip", expected: expected, actual: "different.example.com"} =
             Enum.find(mismatches, &(&1.field == "ip"))

    assert expected == snapshot["target"]["host"]
  end
end
