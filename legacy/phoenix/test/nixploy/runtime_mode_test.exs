defmodule Nixploy.RuntimeModeTest do
  use ExUnit.Case, async: true

  alias Nixploy.RuntimeMode

  test "parses only the supported bounded modes" do
    assert RuntimeMode.parse("remote_control_plane") == {:ok, :remote_control_plane}
    assert RuntimeMode.parse(" LOCAL_RECOVERY ") == {:ok, :local_recovery}

    assert RuntimeMode.parse("production") ==
             {:error, "expected one of: remote_control_plane, local_recovery"}
  end

  test "identifies only the remote control-plane mode" do
    assert RuntimeMode.remote_control_plane?(:remote_control_plane)
    refute RuntimeMode.remote_control_plane?(:local_recovery)
  end
end
