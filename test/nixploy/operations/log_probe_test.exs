defmodule Nixploy.Operations.LogProbeTest do
  use ExUnit.Case, async: false

  alias Nixploy.Operations.LogProbe

  setup do
    root = Path.join(System.tmp_dir!(), "nixploy-log-probe-#{System.unique_integer([:positive])}")
    executable = Path.join(root, "podman")
    File.mkdir_p!(root)

    File.write!(executable, """
    #!/bin/sh
    test "$1" = "--connection" || exit 90
    test "$2" = "nixploy-app-123-production" || exit 91
    test "$3" = "logs" || exit 92
    test "$4" = "--tail" || exit 93
    test "$5" = "200" || exit 94
    test "$6" = "nixploy-app-123-production-green" || exit 95
    printf 'first line\\nsecond line\\n'
    """)

    File.chmod!(executable, 0o755)
    previous = Application.get_env(:nixploy, :podman_executable)
    Application.put_env(:nixploy, :podman_executable, executable)

    on_exit(fn ->
      restore_env(:podman_executable, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "fetches a bounded active-container snapshot with typed arguments" do
    observed = %{
      target_identity: "nixploy-app-123-production",
      active_slot: "green",
      active_container: "nixploy-app-123-production-green"
    }

    assert {:ok, logs} = LogProbe.fetch(observed)
    assert logs.slot == "green"
    assert logs.container_name == observed.active_container
    assert logs.content == "first line\nsecond line"
    assert logs.line_count == 2
    refute logs.truncated
  end

  test "rejects unsafe runtime names before invoking Podman" do
    observed = %{
      target_identity: "nixploy-app;whoami",
      active_slot: "green",
      active_container: "nixploy-app-green"
    }

    assert {:error, {:unsafe_runtime_name, :target_identity, _value}} = LogProbe.fetch(observed)
  end

  defp restore_env(key, nil), do: Application.delete_env(:nixploy, key)
  defp restore_env(key, value), do: Application.put_env(:nixploy, key, value)
end
