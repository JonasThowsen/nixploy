defmodule Nixploy.AuditTest do
  use Nixploy.DataCase, async: true

  alias Nixploy.{Applications, Audit, Deployments, Fixtures}

  test "records the operator for configuration and deployment requests" do
    operator = Fixtures.operator_fixture()

    assert {:ok, repository} =
             Applications.create_repository(
               %{
                 name: "audited-repository",
                 url: "https://example.com/audited.git",
                 default_ref: "main",
                 subdirectory: "."
               },
               operator: operator
             )

    service = Fixtures.service_fixture(%{repository: repository})

    assert {:ok, deployment, _event} =
             Deployments.create_deployment(
               %{service_id: service.id, requested_ref: "main"},
               operator: operator
             )

    events = Audit.list_recent_events(20)

    assert Enum.any?(events, fn event ->
             event.operator_id == operator.id and event.action == "created" and
               event.resource_type == "repository" and event.resource_id == repository.id
           end)

    assert Enum.any?(events, fn event ->
             event.operator_id == operator.id and event.action == "queued" and
               event.resource_type == "deployment" and event.resource_id == deployment.id
           end)
  end

  test "throttles repeated failed login identities and origins" do
    fingerprint = "fingerprint"
    origin = "192.0.2.10"

    for index <- 1..10 do
      assert {:ok, _event} =
               Audit.record(nil, :login_failed, :session, "request-#{index}",
                 outcome: :failed,
                 metadata: %{"email_fingerprint" => fingerprint, "origin" => origin}
               )
    end

    refute Audit.login_allowed?(fingerprint, "198.51.100.1")
    refute Audit.login_allowed?("other", origin)
    assert Audit.login_allowed?("other", "198.51.100.1")
  end
end
