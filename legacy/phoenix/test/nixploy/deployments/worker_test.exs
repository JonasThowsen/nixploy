defmodule Nixploy.Deployments.WorkerTest do
  use Nixploy.DataCase, async: false
  use Oban.Testing, repo: Nixploy.Repo

  alias Nixploy.Deployments
  alias Nixploy.Deployments.Source
  alias Nixploy.Deployments.Worker
  alias Nixploy.Fixtures

  defmodule ConfigProbeStub do
    def validate(_deployment, _workspace, _opts), do: {:ok, "fixture-config-digest"}
  end

  defmodule StatusProbeStub do
    def observe(service) do
      {:ok,
       %{
         target_identity: "nixploy-fixture-production",
         active_slot: "green",
         inactive_slot: "blue",
         active_container: "nixploy-fixture-production-green",
         active_container_state: "running",
         inactive_container: "nixploy-fixture-production-blue",
         inactive_container_state: "exited",
         image: "fixture:latest",
         git_commit: Application.fetch_env!(:nixploy, :worker_test_commit),
         deployed_at: DateTime.utc_now(),
         caddy_route: "nixploy-route-fixture",
         upstream: "127.0.0.1:8081",
         health_url: "https://#{service.domain || "fixture.example.com"}/health",
         health_status: 200,
         health_error: nil
       }}
    end
  end

  defmodule CancellingStatusProbe do
    def observe(service) do
      deployment_id = Application.fetch_env!(:nixploy, :worker_test_deployment_id)
      {:ok, _deployment, _event} = Nixploy.Deployments.request_cancellation(deployment_id)
      Nixploy.Deployments.WorkerTest.StatusProbeStub.observe(service)
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "nixploy-worker-test-#{System.unique_integer([:positive])}")

    repository_path = Path.join(root, "repository")
    executable_path = Path.join(root, "nixploy")
    workspace_root = Path.join(root, "workspaces")

    File.mkdir_p!(root)
    commit = create_repository(repository_path)

    previous_executable = Application.get_env(:nixploy, :legacy_nixploy_executable)
    previous_workspace = Application.get_env(:nixploy, :deployment_workspace_root)
    previous_config_probe = Application.get_env(:nixploy, :deployment_config_probe)
    previous_status_probe = Application.get_env(:nixploy, :deployment_status_probe)
    previous_commit = Application.get_env(:nixploy, :worker_test_commit)
    previous_deployment_id = Application.get_env(:nixploy, :worker_test_deployment_id)
    Application.put_env(:nixploy, :legacy_nixploy_executable, executable_path)
    Application.put_env(:nixploy, :deployment_workspace_root, workspace_root)
    Application.put_env(:nixploy, :deployment_config_probe, ConfigProbeStub)
    Application.put_env(:nixploy, :deployment_status_probe, StatusProbeStub)
    Application.put_env(:nixploy, :worker_test_commit, commit)

    on_exit(fn ->
      restore_env(:legacy_nixploy_executable, previous_executable)
      restore_env(:deployment_workspace_root, previous_workspace)
      restore_env(:deployment_config_probe, previous_config_probe)
      restore_env(:deployment_status_probe, previous_status_probe)
      restore_env(:worker_test_commit, previous_commit)
      restore_env(:worker_test_deployment_id, previous_deployment_id)
      File.rm_rf!(root)
    end)

    {:ok,
     repository_path: repository_path, executable_path: executable_path, expected_commit: commit}
  end

  test "checks out an immutable revision and completes through the legacy CLI", context do
    write_executable!(context.executable_path, """
    #!/bin/sh
    printf 'Building image for %s in %s\\n' "$3" "$PWD"
    printf 'Deployment completed successfully. target=%s\\n' "$3"
    """)

    deployment = enqueue_real_deployment(context.repository_path, "fixture-app")

    assert_enqueued(worker: Worker, args: %{deployment_id: deployment.id})
    assert :ok = perform_job(Worker, %{deployment_id: deployment.id})

    completed = Deployments.get_deployment!(deployment.id)
    assert completed.state == :succeeded
    assert completed.resolved_commit == context.expected_commit
    refute File.exists?(Source.workspace(deployment.id))

    messages = Enum.map(Deployments.list_events(deployment.id), & &1.message)
    assert Enum.any?(messages, &String.contains?(&1, "Resolved main to"))
    assert completed.output.content =~ "target=production"
    assert completed.output.content =~ "/fixture-app"
    assert List.last(messages) == "Deployment succeeded and was verified"
  end

  test "honors cancellation requested during independent verification", context do
    write_executable!(context.executable_path, """
    #!/bin/sh
    printf 'Deployment completed successfully. target=%s\n' "$3"
    """)

    deployment = enqueue_real_deployment(context.repository_path)
    Application.put_env(:nixploy, :worker_test_deployment_id, deployment.id)
    Application.put_env(:nixploy, :deployment_status_probe, CancellingStatusProbe)

    assert :ok = perform_job(Worker, %{deployment_id: deployment.id})

    cancelled = Deployments.get_deployment!(deployment.id)
    assert cancelled.state == :cancelled
    assert cancelled.cancellation_requested_at
  end

  test "fails when independent verification observes a different revision", context do
    write_executable!(context.executable_path, """
    #!/bin/sh
    printf 'Deployment completed successfully. target=%s\n' "$3"
    """)

    Application.put_env(:nixploy, :worker_test_commit, "000000000000")
    deployment = enqueue_real_deployment(context.repository_path)

    assert :ok = perform_job(Worker, %{deployment_id: deployment.id})

    failed = Deployments.get_deployment!(deployment.id)
    assert failed.state == :failed
    assert failed.failure["message"] =~ "verification_commit_mismatch"
    assert failed.output.content =~ "Deployment completed successfully"
  end

  test "does not replay mutation when restart reconciliation is inconclusive", context do
    marker = Path.join(Path.dirname(context.executable_path), "unexpected-replay")

    write_executable!(context.executable_path, """
    #!/bin/sh
    touch #{marker}
    printf 'Deployment completed successfully.\n'
    """)

    deployment = enqueue_real_deployment(context.repository_path)
    {:ok, _, _} = Deployments.transition(deployment.id, :preparing, "Preparing")

    {:ok, _, _} =
      Deployments.transition(deployment.id, :building, "Pinned", %{
        resolved_commit: context.expected_commit,
        configuration_digest: "fixture-config-digest"
      })

    Application.put_env(:nixploy, :worker_test_commit, "000000000000")
    assert :ok = perform_job(Worker, %{deployment_id: deployment.id})

    failed = Deployments.get_deployment!(deployment.id)
    assert failed.state == :failed
    assert failed.failure["message"] =~ "reconciliation_required"
    refute File.exists?(marker)
  end

  test "bounds high-volume compatibility output", context do
    write_executable!(context.executable_path, """
    #!/bin/sh
    i=0
    while [ "$i" -lt 10000 ]; do
      printf 'build-output-%05d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$i"
      i=$((i + 1))
    done
    printf 'Deployment completed successfully. target=%s\n' "$3"
    """)

    deployment = enqueue_real_deployment(context.repository_path)
    assert :ok = perform_job(Worker, %{deployment_id: deployment.id})

    completed = Deployments.get_deployment!(deployment.id)
    assert completed.state == :succeeded
    assert completed.output.line_count == 10_001
    assert completed.output.truncated
    assert byte_size(completed.output.content) <= 65_536
    assert completed.output.content =~ "Deployment completed successfully"
  end

  test "persists a failed CLI result instead of reporting a false success", context do
    write_executable!(context.executable_path, """
    #!/bin/sh
    printf 'remote Podman connection failed\\n'
    exit 7
    """)

    deployment = enqueue_real_deployment(context.repository_path)

    assert :ok = perform_job(Worker, %{deployment_id: deployment.id})

    failed = Deployments.get_deployment!(deployment.id)
    assert failed.state == :failed
    assert failed.resolved_commit == context.expected_commit
    assert failed.failure["message"] =~ "status 7"
    assert failed.failure["message"] =~ "remote Podman connection failed"
  end

  defp enqueue_real_deployment(repository_path, subdirectory \\ ".") do
    repository =
      Fixtures.repository_fixture(%{url: repository_path, subdirectory: subdirectory})

    target = Fixtures.target_fixture(%{name: "production"})
    service = Fixtures.service_fixture(%{repository: repository, target: target})

    assert {:ok, deployment, _event, _job} =
             Deployments.enqueue_deployment(
               %{service_id: service.id, requested_ref: "main"},
               worker: Worker
             )

    deployment
  end

  defp create_repository(path) do
    File.mkdir_p!(path)
    git!(["init", "--quiet", "--initial-branch=main", path])
    git!(["-C", path, "config", "user.name", "Nixploy Test"])
    git!(["-C", path, "config", "user.email", "nixploy@example.test"])
    File.write!(Path.join(path, "flake.nix"), "{ outputs = _: {}; }\n")
    File.mkdir_p!(Path.join(path, "fixture-app"))
    File.write!(Path.join(path, "fixture-app/flake.nix"), "{ outputs = _: {}; }\n")
    git!(["-C", path, "add", "."])
    git!(["-C", path, "commit", "--quiet", "-m", "initial"])
    git!(["-C", path, "rev-parse", "HEAD"])
  end

  defp git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    String.trim(output)
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp restore_env(key, nil), do: Application.delete_env(:nixploy, key)
  defp restore_env(key, value), do: Application.put_env(:nixploy, key, value)
end
