defmodule Nixploy.ManagedApplicationsTest do
  use ExUnit.Case, async: false

  alias Nixploy.ManagedApplications

  setup do
    previous = Application.get_env(:nixploy, :managed_applications)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  test "accepts only host-owned absolute local repository paths" do
    Application.put_env(:nixploy, :managed_applications, %{
      "fixture" => %{
        "project" => "fixture",
        "target" => "production",
        "repository" => "/srv/nixploy/repositories/fixture",
        "repository_identity" => "fixture/repository"
      }
    })

    assert [%{repository: "/srv/nixploy/repositories/fixture"}] = ManagedApplications.list()
  end

  test "rejects Git URLs and relative paths" do
    for path <- ["https://example.test/repository.git", "../repository"] do
      Application.put_env(:nixploy, :managed_applications, %{
        "fixture" => %{
          "project" => "fixture",
          "target" => "production",
          "repository" => path,
          "repository_identity" => "fixture/repository"
        }
      })

      assert_raise RuntimeError, ~r/invalid managed application repository path/, fn ->
        ManagedApplications.list()
      end
    end
  end

  defp restore(nil), do: Application.delete_env(:nixploy, :managed_applications)
  defp restore(value), do: Application.put_env(:nixploy, :managed_applications, value)
end
