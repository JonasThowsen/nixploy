defmodule Nixploy.NativeDeploymentsTest do
  use Nixploy.DataCase, async: false
  use Oban.Testing, repo: Nixploy.Repo

  import Ecto.Query

  alias Nixploy.Audit.Event
  alias Nixploy.Deployments.NativeWorker
  alias Nixploy.Execution.Result
  alias Nixploy.{Fixtures, NativeDeployments}

  @store_path "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-native-fixture"
  @nar_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

  defmodule ExecutorStub do
    def deploy(_deployment, opts) do
      stage = Keyword.fetch!(opts, :stage)

      :ok = stage.(:preparing, "Preparing", %{})

      :ok =
        stage.(:building, "Building", %{
          resource_prefix: "nixploy-native-fixture-prefix-production",
          previous_upstream: "127.0.0.1:18081",
          selected_slot: "blue",
          selected_port: 18_080
        })

      :ok = stage.(:loading, "Loading", %{image_store_path: "/nix/store/image"})

      :ok =
        stage.(:preparing_slot, "Preparing slot", %{
          image_reference: "fixture:latest",
          image_id: "sha256:image"
        })

      :ok = stage.(:starting, "Starting", %{container_name: "fixture-blue"})
      :ok = stage.(:health_checking, "Health", %{container_id: "container-id"})
      :ok = stage.(:switching, "Switching", %{})
      :ok = stage.(:verifying, "Verifying", %{})
      stage.(:succeeded, "Succeeded", %{verified_upstream: "127.0.0.1:18080"})
    end
  end

  defmodule GreenExecutorStub do
    def deploy(_deployment, opts) do
      stage = Keyword.fetch!(opts, :stage)
      :ok = stage.(:preparing, "Preparing", %{})

      :ok =
        stage.(:building, "Building", %{
          resource_prefix: "nixploy-native-fixture-prefix-production",
          previous_upstream: "127.0.0.1:18080",
          selected_slot: "green",
          selected_port: 18_081
        })

      :ok = stage.(:loading, "Loading", %{image_store_path: "/nix/store/image"})

      :ok =
        stage.(:preparing_slot, "Preparing slot", %{
          image_reference: "fixture:latest",
          image_id: "sha256:image"
        })

      :ok = stage.(:starting, "Starting", %{container_name: "fixture-green"})
      :ok = stage.(:health_checking, "Health", %{container_id: "green-container-id"})
      :ok = stage.(:switching, "Switching", %{})
      :ok = stage.(:verifying, "Verifying", %{})
      stage.(:succeeded, "Succeeded", %{verified_upstream: "127.0.0.1:18081"})
    end
  end

  setup do
    previous = Application.get_env(:nixploy, :native_deployment_executor)
    Application.put_env(:nixploy, :native_deployment_executor, ExecutorStub)
    on_exit(fn -> restore_env(:native_deployment_executor, previous) end)
    :ok
  end

  test "enqueues and persists a native deployment with actor and exact staged input" do
    operator = Fixtures.operator_fixture()
    input = staged_input(operator)

    assert {:ok, deployment, job} =
             NativeDeployments.enqueue(input.id, operator: operator, worker: NativeWorker)

    assert deployment.project == "native-fixture"
    assert deployment.target == "production"
    assert deployment.deployment_input_id == input.id
    assert deployment.requested_by_operator_id == operator.id
    assert job.worker == inspect(NativeWorker)
    assert_enqueued(worker: NativeWorker, args: %{native_deployment_id: deployment.id})

    audit =
      Event
      |> where(
        [event],
        event.resource_type == "native_deployment" and event.resource_id == ^deployment.id
      )
      |> Nixploy.Repo.one!()

    assert audit.operator_id == operator.id
    assert audit.action == "native_deployment_queued"
    assert audit.metadata["store_path"] == input.store_path
    assert audit.metadata["nar_hash"] == input.nar_hash
    assert audit.metadata["configuration_digest"] == input.configuration_digest
  end

  test "executes durable native stages to independently verified success" do
    operator = Fixtures.operator_fixture()
    input = staged_input(operator)
    {:ok, deployment, _job} = NativeDeployments.enqueue(input.id, operator: operator)

    assert :ok = perform_job(NativeWorker, %{native_deployment_id: deployment.id})

    completed = NativeDeployments.get_deployment!(deployment.id)
    assert completed.state == :succeeded
    assert completed.resource_prefix == "nixploy-native-fixture-prefix-production"
    assert completed.selected_slot == "blue"
    assert completed.selected_port == 18_080
    assert completed.image_store_path == "/nix/store/image"
    assert completed.image_reference == "fixture:latest"
    assert completed.image_id == "sha256:image"
    assert completed.container_id == "container-id"
    assert completed.verified_upstream == "127.0.0.1:18080"
    assert completed.started_at
    assert completed.finished_at

    assert Enum.map(NativeDeployments.list_events(deployment.id), & &1.stage) == [
             "queued",
             "preparing",
             "building",
             "loading",
             "preparing_slot",
             "starting",
             "health_checking",
             "switching",
             "verifying",
             "succeeded"
           ]
  end

  test "persists exact rollback identity, relationship, actor, and idempotency" do
    operator = Fixtures.operator_fixture()
    input = staged_input(operator)

    {:ok, blue, _job} = NativeDeployments.enqueue(input.id, operator: operator)
    assert :ok = perform_job(NativeWorker, %{native_deployment_id: blue.id})

    Application.put_env(:nixploy, :native_deployment_executor, GreenExecutorStub)
    {:ok, green, _job} = NativeDeployments.enqueue(input.id, operator: operator)
    assert :ok = perform_job(NativeWorker, %{native_deployment_id: green.id})

    blue = NativeDeployments.get_deployment!(blue.id)

    assert {:ok, rollback, job} =
             NativeDeployments.request_rollback(blue.id,
               operator: operator,
               worker: NativeWorker
             )

    assert rollback.operation_kind == :rollback
    assert rollback.rollback_of_id == blue.id
    assert rollback.deployment_input_id == input.id
    assert rollback.expected_image_id == blue.image_id
    assert rollback.expected_slot == "blue"
    assert rollback.requested_by_operator_id == operator.id
    assert job.worker == inspect(NativeWorker)

    audit =
      Event
      |> where(
        [event],
        event.resource_type == "native_deployment" and event.resource_id == ^rollback.id
      )
      |> Nixploy.Repo.one!()

    assert audit.action == "native_rollback_queued"
    assert audit.operator_id == operator.id
    assert audit.metadata["rollback_of_id"] == blue.id
    assert audit.metadata["store_path"] == input.store_path
    assert audit.metadata["nar_hash"] == input.nar_hash
    assert audit.metadata["configuration_digest"] == input.configuration_digest
    assert audit.metadata["image_id"] == blue.image_id
    assert audit.metadata["slot"] == "blue"

    Application.put_env(:nixploy, :native_deployment_executor, ExecutorStub)
    assert :ok = perform_job(NativeWorker, %{native_deployment_id: rollback.id})

    completed = NativeDeployments.get_deployment!(rollback.id)
    assert completed.state == :succeeded
    assert completed.selected_slot == "blue"
    assert completed.verified_upstream == "127.0.0.1:18080"

    terminal_audit =
      Event
      |> where(
        [event],
        event.resource_type == "native_deployment" and event.resource_id == ^rollback.id and
          event.action == "native_rollback_succeeded"
      )
      |> Nixploy.Repo.one!()

    assert terminal_audit.operator_id == operator.id
    assert terminal_audit.outcome == "succeeded"
    assert terminal_audit.metadata["rollback_of_id"] == blue.id
    assert terminal_audit.metadata["image_id"] == blue.image_id

    rollback_id = rollback.id

    assert {:error, {:rollback_already_active, ^rollback_id}} =
             NativeDeployments.request_rollback(blue.id, operator: operator)
  end

  test "serializes active operations for the same flake-derived project and target" do
    operator = Fixtures.operator_fixture()
    input = staged_input(operator)
    assert {:ok, _deployment, _job} = NativeDeployments.enqueue(input.id, operator: operator)

    assert {:error, changeset} = NativeDeployments.enqueue(input.id, operator: operator)
    assert {"has already been taken", _opts} = changeset.errors[:project]
  end

  test "rejects secret and pre-start inputs before a job is inserted" do
    operator = Fixtures.operator_fixture()
    secret_input = staged_input(operator, secrets: %{"app" => "/nix/store/secret-ref"})

    assert {:error, :native_secrets_not_supported} =
             NativeDeployments.enqueue(secret_input.id, operator: operator)

    pre_start_input = staged_input(operator, pre_start: [["/app/migrate"]])

    assert {:error, :native_pre_start_not_supported} =
             NativeDeployments.enqueue(pre_start_input.id, operator: operator)
  end

  defp staged_input(operator, opts \\ []) do
    config = config(opts)

    execute = fn command, _command_opts ->
      case command.args do
        ["path-info" | _] -> ok(Jason.encode!(%{@store_path => %{"narHash" => @nar_hash}}))
        ["eval" | _] -> ok(Jason.encode!(config))
      end
    end

    assert {:ok, input} =
             Nixploy.Deployments.stage_local_store(
               %{store_path: @store_path, selected_target: "production"},
               operator: operator,
               execute: execute,
               path_exists?: fn _path -> true end
             )

    input
  end

  defp config(opts) do
    %{
      "__schema" => "v0.2",
      "project" => "native-fixture",
      "targets" => %{
        "production" => %{
          "image" => "fixtureImage",
          "run" => %{
            "command" => nil,
            "environment" => %{"PORT" => "{port}"},
            "network" => "host",
            "ports" => [],
            "preStart" => Keyword.get(opts, :pre_start, [])
          },
          "secrets" => Keyword.get(opts, :secrets, %{}),
          "web" => %{
            "domain" => "native-fixture.invalid",
            "healthPath" => "/health",
            "slots" => %{"blue" => 18_080, "green" => 18_081}
          }
        }
      }
    }
  end

  defp ok(output),
    do: {:ok, %Result{exit_status: 0, output_tail: output, output_truncated?: false}}

  defp restore_env(key, nil), do: Application.delete_env(:nixploy, key)
  defp restore_env(key, value), do: Application.put_env(:nixploy, key, value)
end
