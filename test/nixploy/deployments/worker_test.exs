defmodule Nixploy.Deployments.WorkerTest do
  use Nixploy.DataCase, async: false
  use Oban.Testing, repo: Nixploy.Repo

  alias Nixploy.Deployments
  alias Nixploy.Deployments.Source
  alias Nixploy.Deployments.Worker
  alias Nixploy.Fixtures

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
    Application.put_env(:nixploy, :legacy_nixploy_executable, executable_path)
    Application.put_env(:nixploy, :deployment_workspace_root, workspace_root)

    on_exit(fn ->
      restore_env(:legacy_nixploy_executable, previous_executable)
      restore_env(:deployment_workspace_root, previous_workspace)
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
    assert Enum.any?(messages, &String.contains?(&1, "target=production"))
    assert Enum.any?(messages, &String.contains?(&1, "/fixture-app"))
    assert List.last(messages) == "Deployment succeeded"
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
