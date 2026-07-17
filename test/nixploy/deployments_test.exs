defmodule Nixploy.DeploymentsTest do
  use Nixploy.DataCase, async: true

  alias Nixploy.Deployments
  alias Nixploy.Deployments.Deployment
  alias Nixploy.Fixtures

  test "creates a queued deployment with an initial event" do
    service = Fixtures.service_fixture()

    assert {:ok, %Deployment{} = deployment, event} =
             Deployments.create_deployment(%{
               service_id: service.id,
               requested_ref: "main"
             })

    assert deployment.state == :queued
    assert deployment.current_stage == :queued
    assert event.stage == "queued"
    assert event.message == "Deployment queued"
  end

  test "persists ordered state transitions and events" do
    deployment = Fixtures.deployment_fixture()

    assert {:ok, preparing, _event} =
             Deployments.transition(deployment.id, :preparing, "Preparing deployment")

    assert preparing.started_at

    assert {:ok, _building, _event} =
             Deployments.transition(deployment.id, :building, "Building image")

    assert Enum.map(Deployments.list_events(deployment.id), & &1.stage) == [
             "queued",
             "preparing",
             "building"
           ]
  end

  test "rejects invalid state transitions" do
    deployment = Fixtures.deployment_fixture()

    assert {:error, {:invalid_transition, :queued, :deploying}} =
             Deployments.transition(deployment.id, :deploying, "Deploying")
  end

  test "records idempotent cancellation requests" do
    deployment = Fixtures.deployment_fixture()

    assert {:ok, requested, event} = Deployments.request_cancellation(deployment.id)
    assert requested.cancellation_requested_at
    assert event.message == "Cancellation requested"
    assert Deployments.cancellation_requested?(deployment.id)

    assert {:ok, requested_again, nil} = Deployments.request_cancellation(deployment.id)
    assert requested_again.cancellation_requested_at == requested.cancellation_requested_at
  end

  test "terminal deployments cannot be cancelled" do
    deployment = Fixtures.deployment_fixture()
    {:ok, _, _} = Deployments.transition(deployment.id, :preparing, "Preparing")
    {:ok, _, _} = Deployments.transition(deployment.id, :building, "Building")
    {:ok, _, _} = Deployments.transition(deployment.id, :deploying, "Deploying")
    {:ok, _, _} = Deployments.transition(deployment.id, :verifying, "Verifying")
    {:ok, succeeded, _} = Deployments.transition(deployment.id, :succeeded, "Complete")

    assert succeeded.finished_at
    assert {:error, {:terminal, :succeeded}} = Deployments.request_cancellation(deployment.id)
  end
end
