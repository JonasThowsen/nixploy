defmodule Nixploy.ControlPlaneHealthTest do
  use Nixploy.DataCase, async: false

  alias Nixploy.ControlPlaneHealth

  setup do
    previous = Application.get_env(:nixploy, :managed_applications)

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

    assert [%{key: "fixture", identity: "owner/fixture", state: :not_observed}] =
             snapshot.repositories

    assert is_binary(snapshot.package_version)
  end
end
