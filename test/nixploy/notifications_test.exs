defmodule Nixploy.NotificationsTest do
  use Nixploy.DataCase, async: true

  alias Nixploy.{Deployments, Fixtures, Notifications}

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
