defmodule Nixploy.LocalHostTest do
  use ExUnit.Case, async: true

  alias Nixploy.Execution.Result
  alias Nixploy.LocalHost

  test "decodes managed and unmanaged local workloads" do
    output =
      Jason.encode!([
        %{
          "Id" => "abcdef1234567890",
          "Names" => ["nixploy-jomat-production-green"],
          "Image" => "localhost/jomat:latest",
          "State" => "running",
          "Status" => "Up 2 hours",
          "Pod" => "",
          "Labels" => %{
            "nixploy.project" => "jomat",
            "nixploy.target" => "production",
            "nixploy.git_commit" => "55ef9e674e5d",
            "nixploy.repository" => "https://github.com/JonasThowsen/jomat",
            "nixploy.deployed_at" => "2026-07-27T12:00:00Z"
          }
        },
        %{
          "Id" => "1234567890abcdef",
          "Names" => ["postgres"],
          "Image" => "docker.io/postgres:17",
          "State" => "exited",
          "Status" => "Exited (0) 1 hour ago",
          "Labels" => %{}
        }
      ])

    assert {:ok, [managed, unmanaged]} = LocalHost.decode(output)

    assert managed.managed?
    assert managed.name == "nixploy-jomat-production-green"
    assert managed.project == "jomat"
    assert managed.target == "production"
    assert managed.slot == "green"
    assert managed.revision == "55ef9e674e5d"
    assert managed.repository == "https://github.com/JonasThowsen/jomat"

    refute unmanaged.managed?
    assert unmanaged.name == "postgres"
    assert unmanaged.state == "exited"
  end

  test "probes Podman without SSH" do
    execute = fn command, _opts ->
      send(self(), {:command, command})
      {:ok, %Result{exit_status: 0, output_tail: "[]"}}
    end

    assert {:ok, inventory} = LocalHost.inventory(execute: execute)
    assert inventory.workloads == []
    assert is_binary(inventory.hostname)
    assert is_binary(inventory.runtime_user)
    assert %DateTime{} = inventory.observed_at

    assert_receive {:command, command}
    assert command.executable == "podman"
    assert command.args == ["ps", "-a", "--format", "json"]
    assert command.max_output_bytes == 1_048_576
  end

  test "rejects truncated Podman inventory" do
    execute = fn _command, _opts ->
      {:ok, %Result{exit_status: 0, output_tail: "[]", output_truncated?: true}}
    end

    assert {:error, :podman_inventory_too_large} = LocalHost.inventory(execute: execute)
  end

  test "returns bounded Podman command failures" do
    execute = fn _command, _opts ->
      {:ok, %Result{exit_status: 125, output_tail: "cannot connect to Podman"}}
    end

    assert {:error, {:podman_failed, 125, "cannot connect to Podman"}} =
             LocalHost.inventory(execute: execute)
  end
end
