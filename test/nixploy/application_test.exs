defmodule Nixploy.ApplicationTest do
  use ExUnit.Case, async: true

  alias Nixploy.Application

  test "web role starts the endpoint but no deployment queues" do
    assert NixployWeb.Endpoint in child_ids(Application.children(:web))
  end

  test "worker role omits all HTTP children" do
    ids = child_ids(Application.children(:worker))

    refute NixployWeb.Endpoint in ids
    refute NixployWeb.Telemetry in ids
    refute DNSCluster in ids
  end

  test "all role starts web and shared infrastructure" do
    ids = child_ids(Application.children(:all))

    assert Nixploy.Repo in ids
    assert Oban in ids
    assert Phoenix.PubSub.Supervisor in ids
    assert NixployWeb.Endpoint in ids
  end

  defp child_ids(children) do
    Enum.map(children, fn child ->
      child
      |> Supervisor.child_spec([])
      |> Map.fetch!(:id)
    end)
  end
end
