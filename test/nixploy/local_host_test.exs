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

  test "decodes inspect metadata, labels, health, timestamps, and published ports" do
    assert {:ok, details} = LocalHost.decode_details(inspect_output())

    assert details.id == "abcdef1234567890"
    assert details.name == "nixploy-jomat-production-green"
    assert details.image == "localhost/jomat:latest"
    assert details.image_id == "sha256:image-id"
    assert details.state == "running"
    assert details.health == "healthy"
    assert details.created_at == ~U[2026-07-27 11:00:00Z]
    assert details.started_at == ~U[2026-07-27 12:00:00Z]
    assert details.managed?
    assert details.project == "jomat"
    assert details.target == "production"
    assert details.revision == "55ef9e674e5d"
    assert details.repository == "https://github.com/JonasThowsen/jomat"
    assert details.slot == "green"
    assert details.published_ports == ["127.0.0.1:8081 → 4000/tcp"]
  end

  test "inspects a container and fetches logs with fixed bounds" do
    execute = fn command, _opts ->
      send(self(), {:command, command})

      case command.args do
        ["container", "inspect" | _rest] ->
          {:ok, %Result{exit_status: 0, output_tail: inspect_output()}}

        ["logs" | _rest] ->
          {:ok,
           %Result{
             exit_status: 0,
             output_tail: "partial line\ncomplete line\nlast line\n",
             output_truncated?: true
           }}
      end
    end

    assert {:ok, details} = LocalHost.workload_details("abcdef1234567890", execute: execute)
    assert details.logs == "complete line\nlast line"
    assert details.log_line_count == 2
    assert details.logs_truncated?

    assert_receive {:command, inspect_command}

    assert inspect_command.args == [
             "container",
             "inspect",
             "--format",
             "json",
             "--",
             "abcdef1234567890"
           ]

    assert inspect_command.timeout == :timer.seconds(15)
    assert inspect_command.max_output_bytes == 1_048_576

    assert_receive {:command, logs_command}
    assert logs_command.args == ["logs", "--tail", "200", "--", "abcdef1234567890"]
    assert logs_command.timeout == :timer.seconds(15)
    assert logs_command.max_output_bytes == 65_536
  end

  test "returns inspect timeout and keeps log timeout on otherwise available details" do
    assert {:error, {:podman_inspect_failed, :timeout}} =
             LocalHost.workload_details("abcdef123456",
               execute: fn _command, _opts -> {:error, :timeout} end
             )

    execute = fn command, _opts ->
      case command.args do
        ["container", "inspect" | _rest] ->
          {:ok, %Result{exit_status: 0, output_tail: inspect_output()}}

        ["logs" | _rest] ->
          {:error, :timeout}
      end
    end

    assert {:ok, details} = LocalHost.workload_details("abcdef123456", execute: execute)
    assert details.logs_error == {:podman_logs_failed, :timeout}
    assert is_nil(details.logs)
  end

  test "probes fixed local health candidates from allowlisted runtime metadata" do
    [container] = Jason.decode!(inspect_output())
    health_output = Jason.encode!([put_in(container, ["NetworkSettings", "Ports"], %{})])

    execute = fn command, _opts ->
      send(self(), {:health_command, command})

      case command.args do
        ["container", "inspect" | _rest] ->
          {:ok, %Result{exit_status: 0, output_tail: health_output}}

        args ->
          status = if String.ends_with?(List.last(args), "/ready"), do: "204", else: "404"
          {:ok, %Result{exit_status: 0, output_tail: status}}
      end
    end

    assert {:ok, observation} =
             LocalHost.observe_health("abcdef1234567890", execute: execute)

    assert observation.status == :healthy
    assert observation.container_state == "running"
    assert observation.endpoint == "http://127.0.0.1:4003/ready"
    assert observation.status_code == 204
    assert is_nil(observation.failure)
    assert %DateTime{} = observation.observed_at

    assert_receive {:health_command, _inspect_command}
    assert_receive {:health_command, health_command}
    assert List.last(health_command.args) == "http://127.0.0.1:4003/health"
    assert health_command.timeout == :timer.seconds(7)
    assert health_command.max_output_bytes == 4_096
    assert_receive {:health_command, ready_command}
    assert List.last(ready_command.args) == "http://127.0.0.1:4003/ready"
  end

  test "refuses unmanaged health probes before invoking curl" do
    [container] = Jason.decode!(inspect_output())
    output = Jason.encode!([put_in(container, ["Config", "Labels"], %{})])

    execute = fn command, _opts ->
      assert command.args |> List.first() == "container"
      {:ok, %Result{exit_status: 0, output_tail: output}}
    end

    assert {:error, :unmanaged_workload} =
             LocalHost.observe_health("abcdef1234567890", execute: execute)
  end

  test "reports stopped containers and missing runtime ports without probing HTTP" do
    [container] = Jason.decode!(inspect_output())

    stopped =
      container
      |> put_in(["State", "Status"], "exited")
      |> put_in(["State", "Running"], false)

    execute_stopped = fn command, _opts ->
      assert command.args |> List.first() == "container"
      {:ok, %Result{exit_status: 0, output_tail: Jason.encode!([stopped])}}
    end

    assert {:ok, stopped_observation} =
             LocalHost.observe_health("abcdef1234567890", execute: execute_stopped)

    assert stopped_observation.status == :unhealthy
    assert stopped_observation.failure == "container state is exited"

    no_port =
      container
      |> put_in(["Config", "Env"], ["LANG=C.UTF-8"])
      |> put_in(["NetworkSettings", "Ports"], %{})

    execute_no_port = fn command, _opts ->
      assert command.args |> List.first() == "container"
      {:ok, %Result{exit_status: 0, output_tail: Jason.encode!([no_port])}}
    end

    assert {:ok, no_port_observation} =
             LocalHost.observe_health("abcdef1234567890", execute: execute_no_port)

    assert no_port_observation.status == :failed
    assert no_port_observation.failure == "no allowlisted local runtime port was reported"
  end

  test "makes health command timeouts explicit" do
    execute = fn command, _opts ->
      case command.args do
        ["container", "inspect" | _rest] ->
          {:ok, %Result{exit_status: 0, output_tail: inspect_output()}}

        _health_args ->
          {:error, :timeout}
      end
    end

    assert {:ok, observation} =
             LocalHost.observe_health("abcdef1234567890", execute: execute)

    assert observation.status == :failed
    assert observation.failure == "health probe timed out after 7 seconds"
  end

  test "rejects malformed inspect output and unsafe identifiers" do
    assert {:error, :unexpected_podman_inspect_json} = LocalHost.decode_details("[]")

    assert {:error, {:invalid_podman_inspect_json, _message}} =
             LocalHost.decode_details("not json")

    assert {:error, {:invalid_container_id, "container;rm"}} =
             LocalHost.workload_details("container;rm",
               execute: fn _command, _opts -> flunk() end
             )
  end

  defp inspect_output do
    Jason.encode!([
      %{
        "Id" => "abcdef1234567890",
        "Name" => "nixploy-jomat-production-green",
        "Image" => "sha256:image-id",
        "ImageName" => "localhost/jomat:latest",
        "Created" => "2026-07-27T11:00:00Z",
        "State" => %{
          "Status" => "running",
          "Running" => true,
          "StartedAt" => "2026-07-27T12:00:00Z",
          "Healthcheck" => %{"Status" => "healthy"}
        },
        "Config" => %{
          "Image" => "localhost/jomat:latest",
          "Env" => ["PORT=4003", "LANG=C.UTF-8"],
          "Labels" => %{
            "io.nixploy.managed" => "true",
            "io.nixploy.project" => "jomat",
            "io.nixploy.target" => "production",
            "io.nixploy.slot" => "green",
            "org.opencontainers.image.revision" => "55ef9e674e5d",
            "org.opencontainers.image.source" => "https://github.com/JonasThowsen/jomat"
          }
        },
        "NetworkSettings" => %{
          "Ports" => %{
            "4000/tcp" => [%{"HostIp" => "127.0.0.1", "HostPort" => "8081"}],
            "4001/tcp" => nil
          }
        }
      }
    ])
  end
end
