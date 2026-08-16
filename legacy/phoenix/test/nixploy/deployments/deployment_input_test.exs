defmodule Nixploy.Deployments.DeploymentInputTest do
  use Nixploy.DataCase, async: false

  import Ecto.Query

  alias Nixploy.Audit.Event
  alias Nixploy.Deployments
  alias Nixploy.Deployments.{DeploymentInput, LocalStoreInput}
  alias Nixploy.Execution.Result
  alias Nixploy.Fixtures

  @store_path "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-local-store-fixture"
  @nar_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

  test "persists immutable verified input, derived snapshot, digest, timestamps, and actor" do
    operator = Fixtures.operator_fixture()

    counts_before = legacy_configuration_counts()
    jobs_before = Nixploy.Repo.aggregate(Oban.Job, :count)

    assert {:ok, staged} =
             Deployments.stage_local_store(
               %{
                 store_path: @store_path,
                 selected_target: "production",
                 expected_nar_hash: @nar_hash
               },
               operator: operator,
               execute: &execute/2,
               path_exists?: fn _path -> true end
             )

    assert staged.input_kind == :local_store
    assert staged.state == :staged
    assert staged.store_path == @store_path
    assert staged.nar_hash == @nar_hash
    assert staged.selected_target == "production"
    assert staged.configuration_digest == LocalStoreInput.digest(staged.derived_snapshot)
    assert staged.derived_snapshot["project"] == "fixture"
    assert staged.derived_snapshot["target"]["image_output"] == "fixtureImage"
    assert staged.derived_snapshot["target"]["slots"] == %{"blue" => 8080, "green" => 8081}
    assert staged.requested_by_operator_id == operator.id
    assert staged.started_at
    assert staged.finished_at
    assert staged.inserted_at

    assert legacy_configuration_counts() == counts_before
    assert Nixploy.Repo.aggregate(Oban.Job, :count) == jobs_before

    audit_events =
      Event
      |> where(
        [event],
        event.resource_type == "deployment_input" and event.resource_id == ^staged.id
      )
      |> order_by([event], asc: event.id)
      |> Nixploy.Repo.all()

    assert Enum.map(audit_events, &{&1.action, &1.outcome, &1.operator_id}) == [
             {"local_store_staging_requested", "requested", operator.id},
             {"local_store_staged", "succeeded", operator.id}
           ]

    assert List.last(audit_events).metadata["nar_hash"] == @nar_hash
    assert List.last(audit_events).metadata["configuration_digest"] == staged.configuration_digest
  end

  test "persists a failed operation and audit evidence when the inspected hash changed" do
    operator = Fixtures.operator_fixture()

    assert {:error, %DeploymentInput{} = failed} =
             Deployments.stage_local_store(
               %{
                 store_path: @store_path,
                 selected_target: "production",
                 expected_nar_hash: "sha256-DIFFERENT"
               },
               operator: operator,
               execute: &execute/2,
               path_exists?: fn _path -> true end
             )

    assert failed.state == :failed
    assert failed.failure["code"] == "nar_hash_changed"
    assert failed.failure["message"] =~ "NAR hash changed"
    assert failed.nar_hash == nil
    assert failed.configuration_digest == nil
    assert failed.finished_at
    assert failed.requested_by_operator_id == operator.id

    assert %Event{operator_id: operator_id, outcome: "failed", metadata: metadata} =
             Event
             |> where(
               [event],
               event.resource_id == ^failed.id and event.action == "local_store_staging_failed"
             )
             |> Nixploy.Repo.one!()

    assert operator_id == operator.id
    assert metadata["failure_code"] == "nar_hash_changed"
  end

  test "persists failure when immutable flake project differs from the authorized project" do
    operator = Fixtures.operator_fixture()

    assert {:error, %DeploymentInput{} = failed} =
             Deployments.stage_local_store(
               %{
                 store_path: @store_path,
                 selected_target: "production",
                 expected_nar_hash: @nar_hash,
                 registration_channel: :ci,
                 source_repository: "JonasThowsen/jomat",
                 source_revision: String.duplicate("a", 40)
               },
               operator: operator,
               expected_project: "jomat",
               execute: &execute/2,
               path_exists?: fn _path -> true end
             )

    assert failed.state == :failed
    assert failed.registration_channel == :ci
    assert failed.failure["code"] == "project_mismatch"
    assert failed.failure["message"] =~ "authorized project"
  end

  test "requires an audit actor and does not create an operation without one" do
    assert {:error, changeset} =
             Deployments.stage_local_store(%{
               store_path: @store_path,
               selected_target: "production"
             })

    assert "can't be blank" in errors_on(changeset).requested_by_operator_id
    assert Deployments.list_deployment_inputs() == []
  end

  test "crosses real Nix, PostgreSQL, and audit boundaries for the no-secret fixture" do
    nix = System.find_executable("nix") || flunk("nix executable is required")
    fixture = Path.expand("test/fixtures/local_store_flake")
    operator = Fixtures.operator_fixture()

    {store_path, 0} = System.cmd(nix, ["store", "add-path", fixture], stderr_to_stdout: true)
    store_path = String.trim(store_path)

    assert {:ok, staged} =
             Deployments.stage_local_store(
               %{store_path: store_path, selected_target: "production"},
               operator: operator
             )

    persisted = Deployments.get_deployment_input!(staged.id)
    assert persisted.state == :staged
    assert persisted.store_path == store_path
    assert String.starts_with?(persisted.nar_hash, "sha256-")
    assert persisted.derived_snapshot["project"] == "local-store-tracer"
    assert persisted.derived_snapshot["target"]["domain"] == "fixture.nixploy.invalid"
    assert persisted.requested_by_operator.id == operator.id
  end

  test "terminal input changesets reject mutation" do
    operator = Fixtures.operator_fixture()

    assert {:ok, staged} =
             Deployments.stage_local_store(
               %{store_path: @store_path, selected_target: "production"},
               operator: operator,
               execute: &execute/2,
               path_exists?: fn _path -> true end
             )

    changeset =
      DeploymentInput.staged_changeset(staged, %{
        nar_hash: "sha256-replaced",
        selected_target: "production",
        derived_snapshot: staged.derived_snapshot,
        configuration_digest: staged.configuration_digest,
        state: :staged,
        finished_at: DateTime.utc_now()
      })

    refute changeset.valid?
    assert "terminal deployment input cannot be changed" in errors_on(changeset).state
  end

  defp execute(command, _opts) do
    case command.args do
      ["path-info" | _rest] ->
        ok_result(Jason.encode!(%{@store_path => %{"narHash" => @nar_hash}}))

      ["eval" | _rest] ->
        ok_result(Jason.encode!(config()))
    end
  end

  defp ok_result(output) do
    {:ok, %Result{exit_status: 0, output_tail: output, output_truncated?: false}}
  end

  defp config do
    %{
      "__schema" => "v0.2",
      "project" => "fixture",
      "targets" => %{
        "production" => %{
          "image" => "fixtureImage",
          "web" => %{
            "domain" => "fixture.example.test",
            "healthPath" => "/ready",
            "slots" => %{"blue" => 8080, "green" => 8081}
          }
        }
      }
    }
  end

  defp legacy_configuration_counts do
    %{
      repositories: Nixploy.Repo.aggregate(Nixploy.Applications.Repository, :count),
      targets: Nixploy.Repo.aggregate(Nixploy.Fleet.Target, :count),
      services: Nixploy.Repo.aggregate(Nixploy.Applications.Service, :count),
      deployments: Nixploy.Repo.aggregate(Nixploy.Deployments.Deployment, :count)
    }
  end
end
