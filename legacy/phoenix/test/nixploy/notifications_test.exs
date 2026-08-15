defmodule Nixploy.NotificationsTest do
  use Nixploy.DataCase, async: true

  alias Nixploy.{Deployments, Fixtures, Notifications, Operations}

  test "publishes service status changes to the global topic" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    Notifications.subscribe()

    assert {:ok, _observation, _job} = Operations.request_status_refresh(service.id)

    service_id = service.id
    assert_receive {:service_status_changed, ^service_id}
  end

  test "publishes service log changes to the global topic" do
    service = Fixtures.service_fixture(%{domain: "app.example.com"})
    Notifications.subscribe()

    assert {:ok, _snapshot, _job} = Operations.request_log_snapshot(service.id)

    service_id = service.id
    assert_receive {:service_logs_changed, ^service_id}
  end

  test "publishes durable deployment changes to global and deployment topics" do
    service = Fixtures.service_fixture()

    assert {:ok, deployment, _event} =
             Deployments.create_deployment(%{
               service_id: service.id,
               requested_ref: "main"
             })

    Notifications.subscribe()
    Notifications.subscribe(deployment.id)

    assert {:ok, _deployment, _event} =
             Deployments.transition(deployment.id, :preparing, "Preparing")

    deployment_id = deployment.id
    assert_receive {:deployment_changed, ^deployment_id}
    assert_receive {:deployment_changed, ^deployment_id}
  end
end
