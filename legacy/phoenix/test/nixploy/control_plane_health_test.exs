defmodule Nixploy.ControlPlaneHealthTest do
  use Nixploy.DataCase, async: false

  alias Nixploy.{ControlPlaneHealth, WorkerHeartbeat}

  setup do
    previous = Application.get_env(:nixploy, :managed_applications)
    previous_backup_enabled = System.get_env("NIXPLOY_BACKUP_ENABLED")
    previous_backup_schedule = System.get_env("NIXPLOY_BACKUP_SCHEDULE")
    System.delete_env("NIXPLOY_BACKUP_ENABLED")
    System.delete_env("NIXPLOY_BACKUP_SCHEDULE")
    Nixploy.Repo.delete_all(WorkerHeartbeat)

    Application.put_env(:nixploy, :managed_applications, %{
      "fixture" => %{
        "project" => "fixture",
        "target" => "production",
        "repository" => "/home/jonas/coding/fixture",
        "repository_identity" => "owner/fixture"
      }
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nixploy, :managed_applications, previous),
        else: Application.delete_env(:nixploy, :managed_applications)

      restore_env("NIXPLOY_BACKUP_ENABLED", previous_backup_enabled)
      restore_env("NIXPLOY_BACKUP_SCHEDULE", previous_backup_schedule)
    end)

    :ok
  end

  test "reports web-safe database, queue, package and repository readiness" do
    snapshot = ControlPlaneHealth.snapshot()

    assert snapshot.database.ready?
    assert is_binary(snapshot.database.version)
    assert snapshot.web.ready?
    assert snapshot.web.role in [:web, :worker, :all]
    assert snapshot.queues == %{available: 0, scheduled: 0, executing: 0, retryable: 0}
    assert snapshot.workers == %{active_count: 0, singleton?: false, latest: nil}
    refute snapshot.backup.enabled?
    assert snapshot.backup.schedule == nil

    assert [%{key: "fixture", identity: "owner/fixture", state: :not_observed}] =
             snapshot.repositories

    assert is_binary(snapshot.package_version)
  end

  test "reports singleton worker fencing and NixOS-owned backup schedule" do
    now = DateTime.utc_now()
    {:ok, heartbeat} = WorkerHeartbeat.record(Ecto.UUID.generate(), now, now: now)
    System.put_env("NIXPLOY_BACKUP_ENABLED", "true")
    System.put_env("NIXPLOY_BACKUP_SCHEDULE", "daily")

    snapshot = ControlPlaneHealth.snapshot()
    assert snapshot.workers.active_count == 1
    assert snapshot.workers.singleton?
    assert snapshot.workers.latest.runtime_id == heartbeat.runtime_id
    assert snapshot.backup == %{enabled?: true, schedule: "daily"}

    {:ok, _second} = WorkerHeartbeat.record(Ecto.UUID.generate(), now, now: now)
    refute ControlPlaneHealth.snapshot().workers.singleton?
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
