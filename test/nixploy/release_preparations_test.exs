defmodule Nixploy.ReleasePreparationsTest do
  use Nixploy.DataCase, async: false
  use Oban.Testing, repo: Nixploy.Repo

  alias Nixploy.{Deployments, Fixtures, Repo}
  alias Nixploy.Deployments.MainPreparationWorker

  defmodule SourceStub do
    @oid String.duplicate("d", 40)

    def resolve_main(application, _opts) do
      send(self(), {:resolved, application.repository, application.source_ref})
      {:ok, @oid}
    end

    def materialize(input, application, _opts) do
      if input.source_revision != @oid, do: raise("OID was not persisted before fetch")
      send(self(), {:materialized, input.source_revision, application.target})

      snapshot = %{
        "schema" => "v0.2",
        "project" => application.project,
        "target" => %{
          "name" => application.target,
          "image_output" => "fixtureImage",
          "domain" => "fixture.example.test",
          "health_path" => "/health",
          "slots" => %{"blue" => 8080, "green" => 8081},
          "run" => %{
            "command" => nil,
            "pre_start" => [],
            "environment" => %{},
            "network" => nil,
            "ports" => []
          },
          "credential_references" => %{},
          "pre_start_declared" => false,
          "secrets_declared" => false
        }
      }

      {:ok,
       %{
         store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-direct-main",
         nar_hash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
         commit_subject: "Prepared exact main",
         commit_timestamp: ~U[2026-08-05 09:00:00Z],
         derived_snapshot: snapshot,
         configuration_digest: Nixploy.Deployments.LocalStoreInput.digest(snapshot)
       }}
    end
  end

  setup do
    old_apps = Application.get_env(:nixploy, :managed_applications)
    old_source = Application.get_env(:nixploy, :main_source)

    Application.put_env(:nixploy, :managed_applications, %{
      "fixture" => %{
        "project" => "fixture",
        "target" => "production",
        "repository" => "/srv/nixploy/repositories/fixture",
        "repository_identity" => "fixture/repository",
        "subdirectory" => "."
      }
    })

    Application.put_env(:nixploy, :main_source, SourceStub)

    on_exit(fn ->
      restore(:managed_applications, old_apps)
      restore(:main_source, old_source)
    end)

    :ok
  end

  test "web action only persists and enqueues, then worker pins and prepares the exact release" do
    operator = Fixtures.operator_fixture()

    assert {:ok, queued, job} = Deployments.prepare_main("fixture", operator: operator)
    assert queued.input_kind == :git_main
    assert queued.state == :staging
    assert queued.source_ref == "refs/heads/main"
    assert queued.source_revision == nil
    assert queued.store_path == nil
    assert job.args == %{deployment_input_id: queued.id}
    refute_received {:resolved, _, _}

    assert :ok =
             MainPreparationWorker.perform(%Oban.Job{
               args: %{"deployment_input_id" => queued.id}
             })

    assert_received {:resolved, "/srv/nixploy/repositories/fixture", "refs/heads/main"}
    assert_received {:materialized, revision, "production"}
    assert revision == String.duplicate("d", 40)

    staged = Deployments.get_deployment_input!(queued.id)
    assert staged.state == :staged
    assert staged.application_key == "fixture"
    assert staged.source_repository == "fixture/repository"
    assert staged.source_revision == revision
    assert staged.commit_subject == "Prepared exact main"
    assert staged.store_path == "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-direct-main"
    assert staged.configuration_digest

    assert Enum.map(Deployments.list_input_events(staged.id), & &1.stage) == [
             "queued",
             "resolving",
             "resolved",
             "snapshotting",
             "staged"
           ]
  end

  test "concurrent preparation requests converge to the one active operation" do
    operator = Fixtures.operator_fixture()

    assert {:ok, first, first_job} = Deployments.prepare_main("fixture", operator: operator)
    assert {:ok, second, second_job} = Deployments.prepare_main("fixture", operator: operator)

    assert second.id == first.id
    assert second_job.id == first_job.id
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert Enum.map(Deployments.list_input_events(first.id), & &1.stage) == ["queued"]
  end

  test "a duplicate exact commit returns a bounded existing-release result without materializing twice" do
    operator = Fixtures.operator_fixture()
    assert {:ok, first, _job} = Deployments.prepare_main("fixture", operator: operator)
    assert :ok = perform(first.id)
    assert_received {:materialized, _revision, "production"}

    assert {:ok, duplicate, _job} = Deployments.prepare_main("fixture", operator: operator)
    assert :ok = perform(duplicate.id)

    refute_received {:materialized, _revision, "production"}
    duplicate = Deployments.get_deployment_input!(duplicate.id)
    assert duplicate.state == :failed
    assert duplicate.failure["code"] == "release_already_prepared"
    assert duplicate.failure["message"] =~ first.id
  end

  test "rejects an application identity outside the trusted map" do
    operator = Fixtures.operator_fixture()

    assert {:error, :managed_application_not_found} =
             Deployments.prepare_main("other", operator: operator)

    assert Deployments.list_deployment_inputs() == []
  end

  defp perform(id) do
    MainPreparationWorker.perform(%Oban.Job{args: %{"deployment_input_id" => id}})
  end

  defp restore(key, nil), do: Application.delete_env(:nixploy, key)
  defp restore(key, value), do: Application.put_env(:nixploy, key, value)
end
