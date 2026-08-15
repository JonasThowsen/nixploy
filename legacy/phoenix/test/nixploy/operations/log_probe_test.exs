defmodule Nixploy.Operations.LogProbeTest do
  use ExUnit.Case, async: false

  alias Nixploy.Operations.LogProbe

  setup do
    root = Path.join(System.tmp_dir!(), "nixploy-log-probe-#{System.unique_integer([:positive])}")
    executable = Path.join(root, "ssh")
    File.mkdir_p!(root)

    File.write!(executable, """
    #!/bin/sh
    test "$1" = "-o" || exit 90
    test "$2" = "BatchMode=yes" || exit 91
    test "$4" = "StrictHostKeyChecking=yes" || exit 92
    test "$6" = "ConnectTimeout=10" || exit 93
    test "$7" = "-p" || exit 94
    test "$8" = "2222" || exit 95
    test "$9" = "--" || exit 96
    test "${10}" = "deploy@app.example.com" || exit 97
    test "${11}" = "podman logs --tail 200 nixploy-app-123-production-green" || exit 98
    printf 'first line\nsecond line\n'
    """)

    File.chmod!(executable, 0o755)
    previous = Application.get_env(:nixploy, :ssh_executable)
    Application.put_env(:nixploy, :ssh_executable, executable)

    on_exit(fn ->
      restore_env(:ssh_executable, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "fetches a bounded active-container snapshot over strict SSH" do
    service = %{
      target: %{host: "app.example.com", ssh_user: "deploy", ssh_port: 2222}
    }

    observed = %{
      target_identity: "nixploy-app-123-production",
      active_slot: "green",
      active_container: "nixploy-app-123-production-green"
    }

    assert {:ok, logs} = LogProbe.fetch(service, observed)
    assert logs.slot == "green"
    assert logs.container_name == observed.active_container
    assert logs.content == "first line\nsecond line"
    assert logs.line_count == 2
    refute logs.truncated
  end

  test "rejects unsafe runtime names before invoking SSH" do
    service = %{
      target: %{host: "app.example.com", ssh_user: "deploy", ssh_port: 2222}
    }

    observed = %{
      target_identity: "nixploy-app;whoami",
      active_slot: "green",
      active_container: "nixploy-app-green"
    }

    assert {:error, {:unsafe_runtime_name, :target_identity, _value}} =
             LogProbe.fetch(service, observed)
  end

  defp restore_env(key, nil), do: Application.delete_env(:nixploy, key)
  defp restore_env(key, value), do: Application.put_env(:nixploy, key, value)
end
