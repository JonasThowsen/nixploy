defmodule Nixploy.Deployments.SimulatedWorkerTest do
  use Nixploy.DataCase, async: true
  use Oban.Testing, repo: Nixploy.Repo

  alias Nixploy.Deployments
  alias Nixploy.Deployments.SimulatedWorker
  alias Nixploy.Fixtures

  test "enqueues and executes a complete simulated deployment" do
    service = Fixtures.service_fixture()

    assert {:ok, deployment, _event, job} =
             Deployments.enqueue_deployment(%{
               service_id: service.id,
               requested_ref: "main"
             })

    assert job.worker == inspect(SimulatedWorker)
    assert_enqueued(worker: SimulatedWorker, args: %{deployment_id: deployment.id})
    assert :ok = perform_job(SimulatedWorker, %{deployment_id: deployment.id})

    completed = Deployments.get_deployment!(deployment.id)
    assert completed.state == :succeeded
    assert completed.finished_at

    assert Enum.map(Deployments.list_events(deployment.id), & &1.stage) == [
             "queued",
             "preparing",
             "building",
             "deploying",
             "verifying",
             "succeeded"
           ]
  end

  test "honours a cancellation request before starting work" do
    deployment = Fixtures.deployment_fixture()
    {:ok, _deployment, _event} = Deployments.request_cancellation(deployment.id)

    assert :ok = perform_job(SimulatedWorker, %{deployment_id: deployment.id})

    cancelled = Deployments.get_deployment!(deployment.id)
    assert cancelled.state == :cancelled
    assert cancelled.finished_at
  end

  test "resumes from the last persisted stage" do
    deployment = Fixtures.deployment_fixture()
    {:ok, _, _} = Deployments.transition(deployment.id, :preparing, "Preparing")
    {:ok, _, _} = Deployments.transition(deployment.id, :building, "Building")

    assert :ok = perform_job(SimulatedWorker, %{deployment_id: deployment.id})

    assert Deployments.get_deployment!(deployment.id).state == :succeeded

    stages = Enum.map(Deployments.list_events(deployment.id), & &1.stage)
    assert Enum.count(stages, &(&1 == "preparing")) == 1
    assert Enum.count(stages, &(&1 == "building")) == 1
  end
end
