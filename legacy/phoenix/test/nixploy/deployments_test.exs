defmodule Nixploy.DeploymentsTest do
  use Nixploy.DataCase, async: true

  import Ecto.Query

  alias Nixploy.Deployments
  alias Nixploy.Deployments.{Deployment, TargetLease}
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
    assert deployment.service_snapshot["target"]["id"] == service.target_id
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

    assert {:error, :cancellation_requested} =
             Deployments.transition(deployment.id, :preparing, "Must not continue")

    assert {:ok, requested_again, nil} = Deployments.request_cancellation(deployment.id)
    assert requested_again.cancellation_requested_at == requested.cancellation_requested_at
  end

  test "redeploys an exact commit with the original immutable snapshot" do
    service = Fixtures.service_fixture()
    deployment = Fixtures.deployment_fixture(%{service: service})
    original_host = deployment.service_snapshot["target"]["host"]
    commit = String.duplicate("a", 40)

    {:ok, _, _} = Deployments.transition(deployment.id, :preparing, "Preparing")

    {:ok, _, _} =
      Deployments.transition(deployment.id, :building, "Building", %{
        resolved_commit: commit,
        configuration_digest: "digest"
      })

    {:ok, _, _} = Deployments.transition(deployment.id, :deploying, "Deploying")
    {:ok, _, _} = Deployments.transition(deployment.id, :verifying, "Verifying")
    {:ok, _, _} = Deployments.transition(deployment.id, :succeeded, "Succeeded")

    target = Nixploy.Fleet.get_target!(service.target_id)
    {:ok, _target} = Nixploy.Fleet.update_target(target, %{host: "changed.example.com"})

    assert {:ok, retry, _event, _job} =
             Deployments.retry_deployment(deployment.id,
               worker: Nixploy.Deployments.SimulatedWorker
             )

    assert retry.requested_ref == commit
    assert retry.retry_of_deployment_id == deployment.id
    assert retry.service_snapshot["target"]["host"] == original_host
  end

  test "retains bounded deployment output" do
    deployment = Fixtures.deployment_fixture()
    assert {:ok, _output} = Deployments.reset_output(deployment.id)

    content = String.duplicate("line payload\n", 8_000)
    assert {:ok, output} = Deployments.append_output(deployment.id, content, 8_000)

    assert byte_size(output.content) <= 65_536
    assert output.line_count == 8_000
    assert output.truncated
  end

  test "serializes target leases with increasing fencing tokens" do
    deployment = Fixtures.deployment_fixture()
    target_id = deployment.service_snapshot["target"]["id"]

    assert {:ok, first} = TargetLease.acquire(target_id, deployment.id)
    assert first.fencing_token == 1
    assert {:error, :target_busy} = TargetLease.acquire(target_id, deployment.id)

    assert :ok = TargetLease.release(first)
    assert {:ok, second} = TargetLease.acquire(target_id, deployment.id)
    assert second.fencing_token == 2
    assert :ok = TargetLease.release(second)
  end

  test "an expired owner cannot revive its lease after takeover eligibility" do
    deployment = Fixtures.deployment_fixture()
    target_id = deployment.service_snapshot["target"]["id"]
    {:ok, first} = TargetLease.acquire(target_id, deployment.id)

    expired_at = DateTime.add(DateTime.utc_now(), -60, :second)

    TargetLease
    |> where([lease], lease.id == ^first.id)
    |> Nixploy.Repo.update_all(set: [expires_at: expired_at])

    assert {:error, :lease_lost} = TargetLease.maintain(first)
    assert {:ok, second} = TargetLease.acquire(target_id, deployment.id)
    assert second.fencing_token == first.fencing_token + 1
    assert :ok = TargetLease.release(second)
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
