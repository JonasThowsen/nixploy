defmodule Nixploy.Operations.StatusProbeTest do
  use Nixploy.DataCase, async: true

  alias Nixploy.Fixtures
  alias Nixploy.Operations.StatusProbe

  test "derives the active web slot and deployment metadata" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    identity = "nixploy-app-123-production"

    containers = [
      %{
        "Names" => ["#{identity}-green"],
        "State" => "running",
        "Status" => "Up 2 minutes",
        "Image" => "localhost/app:latest",
        "Labels" => %{
          "nixploy.git_commit" => "abcdef123456",
          "nixploy.deployed_at" => "2026-07-22T13:26:59Z"
        }
      }
    ]

    routes = [
      %{
        "@id" => "nixploy-route-#{identity}",
        "match" => [%{"host" => ["app.example.com"]}],
        "handle" => [
          %{
            "handler" => "subroute",
            "routes" => [
              %{
                "handle" => [
                  %{
                    "handler" => "reverse_proxy",
                    "upstreams" => [%{"dial" => "127.0.0.1:8081"}]
                  }
                ]
              }
            ]
          }
        ]
      }
    ]

    assert {:ok, observed} = StatusProbe.observed_runtime(service, containers, routes)
    assert observed.target_identity == identity
    assert observed.active_slot == "green"
    assert observed.inactive_slot == "blue"
    assert observed.active_container == "#{identity}-green"
    assert observed.inactive_container == "#{identity}-blue"
    assert observed.inactive_container_state == "absent"
    assert observed.image == "localhost/app:latest"
    assert observed.git_commit == "abcdef123456"
    assert observed.deployed_at == ~U[2026-07-22 13:26:59Z]
    assert observed.upstream == "127.0.0.1:8081"
    assert observed.health_url == "https://app.example.com/health"
  end
end
