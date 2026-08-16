defmodule Nixploy.WorkerHeartbeatTest do
  use Nixploy.DataCase, async: false

  alias Nixploy.WorkerHeartbeat

  test "records bounded capability presence without credential paths" do
    old_cli = Application.get_env(:nixploy, :remote_cli_executable)
    old_policy = Application.get_env(:nixploy, :deployment_policy_component)
    old_sops = System.get_env("SOPS_AGE_KEY_FILE")

    on_exit(fn ->
      restore(:remote_cli_executable, old_cli)
      restore(:deployment_policy_component, old_policy)
      restore_env("SOPS_AGE_KEY_FILE", old_sops)
    end)

    Application.put_env(:nixploy, :remote_cli_executable, "/nix/store/cli/bin/nixploy")
    Application.put_env(:nixploy, :deployment_policy_component, "/nix/store/policy/policy.wasm")
    System.put_env("SOPS_AGE_KEY_FILE", "/run/credentials/worker/age-key")

    now = DateTime.utc_now()
    runtime_id = Ecto.UUID.generate()

    assert {:ok, heartbeat} =
             WorkerHeartbeat.record(runtime_id, now,
               now: now,
               hostname: "netcup-dev",
               os_pid: 1234
             )

    assert heartbeat.hostname == "netcup-dev"

    assert heartbeat.capabilities == %{
             "deployment_policy" => true,
             "remote_cli" => true,
             "sops_identity" => true,
             "ssh_identity" => false
           }

    refute inspect(heartbeat.capabilities) =~ "/run/credentials"
    assert WorkerHeartbeat.available?(heartbeat)
  end

  test "marks stale or missing workers unavailable" do
    refute WorkerHeartbeat.available?(nil)

    stale = %WorkerHeartbeat{last_seen_at: DateTime.add(DateTime.utc_now(), -60, :second)}
    refute WorkerHeartbeat.available?(stale)
  end

  defp restore(key, nil), do: Application.delete_env(:nixploy, key)
  defp restore(key, value), do: Application.put_env(:nixploy, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
