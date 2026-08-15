defmodule Nixploy.RuntimeRoleTest do
  use ExUnit.Case, async: true

  alias Nixploy.RuntimeRole

  test "parses supported roles without creating atoms" do
    assert RuntimeRole.parse("web") == {:ok, :web}
    assert RuntimeRole.parse(" WORKER ") == {:ok, :worker}
    assert RuntimeRole.parse("All") == {:ok, :all}
  end

  test "rejects unsupported roles" do
    assert RuntimeRole.parse("scheduler") ==
             {:error, "expected one of: web, worker, all"}

    assert_raise ArgumentError, ~r/invalid NIXPLOY_ROLE/, fn ->
      RuntimeRole.parse!("scheduler")
    end
  end

  test "identifies web and worker capabilities" do
    assert RuntimeRole.web?(:web)
    refute RuntimeRole.worker?(:web)

    refute RuntimeRole.web?(:worker)
    assert RuntimeRole.worker?(:worker)

    assert RuntimeRole.web?(:all)
    assert RuntimeRole.worker?(:all)
  end
end
