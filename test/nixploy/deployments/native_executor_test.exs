defmodule Nixploy.Deployments.NativeExecutorTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.{DeploymentInput, LocalStoreInput, NativeDeployment, NativeExecutor}
  alias Nixploy.Execution.Result

  @store_path "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-native-fixture"
  @nar_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  @image_id "sha256:fixture-image-id"

  test "builds, loads, starts, health-checks, switches, and reads back one new fixture" do
    parent = self()
    operation = operation()

    execute = fn command, opts ->
      send(parent, {:command, command, opts})
      response(command)
    end

    stage = fn state, message, attrs ->
      send(parent, {:stage, state, message, attrs})
      :ok
    end

    assert :ok =
             NativeExecutor.deploy(operation,
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: stage,
               cancelled?: fn -> false end,
               health_attempts: 1,
               health_delay_ms: 0
             )

    messages = drain_messages([])
    stages = for {:stage, state, _message, _attrs} <- messages, do: state

    assert stages == [
             :preparing,
             :building,
             :loading,
             :preparing_slot,
             :starting,
             :health_checking,
             :switching,
             :verifying,
             :succeeded
           ]

    assert {:stage, :building, _, %{selected_slot: "blue", selected_port: 18_080}} =
             Enum.find(messages, &match?({:stage, :building, _, _}, &1))

    commands = for {:command, command, _opts} <- messages, do: command

    assert Enum.any?(commands, fn command ->
             command.executable == "nix" and
               command.args == [
                 "build",
                 "--quiet",
                 "--json",
                 "--no-link",
                 "#{@store_path}#fixtureImage"
               ] and command.timeout == 900_000 and
               command.max_output_bytes == 1_048_576
           end)

    run = Enum.find(commands, &match?(["run", "--detach" | _], &1.args))
    assert run.executable == "podman"
    assert "--network" in run.args
    assert "host" in run.args
    assert "PORT=18080" in run.args
    assert "io.nixploy.managed=true" in run.args
    assert "io.nixploy.slot=blue" in run.args
    refute Enum.any?(commands, &(&1.executable in ["sh", "bash"]))

    health_index = Enum.find_index(commands, &health_command?/1)

    switch_index =
      Enum.find_index(commands, fn command ->
        command.executable == "curl" and "POST" in command.args
      end)

    assert health_index < switch_index

    assert Enum.any?(commands, fn command ->
             command.executable == "curl" and
               Enum.any?(command.args, &String.ends_with?(&1, "/upstreams"))
           end)
  end

  test "fails closed on an unmanaged candidate name before build or mutation" do
    operation = operation()
    prefix = derived_prefix("native-fixture", "production")

    execute = fn command, _opts ->
      send(self(), {:command, command})

      case command.args do
        ["path-info" | _] ->
          ok(path_info_json())

        ["eval" | _] ->
          ok(Jason.encode!(config()))

        ["ps", "-a", "--format", "json"] ->
          ok(Jason.encode!([%{"Names" => ["#{prefix}-blue"], "Labels" => %{}}]))
      end
    end

    assert {:error, {:unmanaged_name_collision, name}} =
             NativeExecutor.deploy(operation,
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end
             )

    assert name == "#{prefix}-blue"
    commands = drain_commands([])
    refute Enum.any?(commands, &match?(["build" | _], &1.args))
    refute Enum.any?(commands, &(&1.executable == "curl" and "PATCH" in &1.args))
    refute Enum.any?(commands, &match?(["rm" | _], &1.args))
  end

  test "failed candidate health leaves the previously routed managed slot untouched" do
    parent = self()
    prefix = "nixploy-native-fixture-existing-production"

    active = %{
      "Names" => ["#{prefix}-green"],
      "State" => "running",
      "Labels" => %{
        "io.nixploy.managed" => "true",
        "io.nixploy.project" => "native-fixture",
        "io.nixploy.target" => "production"
      }
    }

    execute = fn command, _opts ->
      send(parent, {:command, command})

      case {command.executable, command.args} do
        {"nix", ["path-info" | _]} ->
          ok(path_info_json())

        {"nix", ["eval" | _]} ->
          ok(Jason.encode!(config()))

        {"nix", ["build" | _]} ->
          ok(Jason.encode!([%{"outputs" => %{"out" => "/nix/store/image-tar"}}]))

        {"podman", ["ps", "-a", "--format", "json"]} ->
          ok(Jason.encode!([active]))

        {"podman", ["load" | _]} ->
          ok("Loaded image: localhost/native-fixture:latest\n")

        {"podman", ["image", "inspect" | _]} ->
          ok(Jason.encode!([%{"Id" => @image_id}]))

        {"podman", ["run", "--detach" | _]} ->
          ok("candidate-container-id\n")

        {"podman", ["container", "inspect" | _]} ->
          response(command)

        {"curl", args} ->
          url = List.last(args)

          cond do
            String.contains?(url, "nixploy-route-") ->
              ok(
                Jason.encode!(%{"match" => [%{"host" => ["native-fixture.invalid"]}]}) <> "\n200"
              )

            String.contains?(url, "/upstreams") ->
              ok("[{\"dial\":\"127.0.0.1:18081\"}]\n200")

            String.contains?(url, "/health") ->
              {:ok, %Result{exit_status: 22, output_tail: "HTTP 503", output_truncated?: false}}
          end
      end
    end

    assert {:error, :health_failed} =
             NativeExecutor.deploy(operation(),
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end,
               health_attempts: 2,
               health_delay_ms: 0
             )

    commands = drain_commands([])

    refute Enum.any?(
             commands,
             &(&1.executable == "curl" and ("PATCH" in &1.args or "POST" in &1.args))
           )

    refute Enum.any?(commands, &match?(["stop" | _], &1.args))
    refute Enum.any?(commands, &match?(["rm" | _], &1.args))
  end

  test "propagates cancellation to every bounded command" do
    parent = self()

    execute = fn command, opts ->
      send(parent, {:opts, command.args, opts})
      {:error, :cancelled}
    end

    assert {:error, :cancelled} =
             NativeExecutor.deploy(operation(),
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end
             )

    assert_receive {:opts, ["path-info" | _], [cancelled?: cancelled?]}
    refute cancelled?.()
  end

  defp response(%{executable: "nix", args: ["path-info" | _]}), do: ok(path_info_json())
  defp response(%{executable: "nix", args: ["eval" | _]}), do: ok(Jason.encode!(config()))

  defp response(%{executable: "nix", args: ["build" | _]}) do
    ok(Jason.encode!([%{"outputs" => %{"out" => "/nix/store/image-tar"}}]))
  end

  defp response(%{executable: "podman", args: ["ps", "-a", "--format", "json"]}),
    do: ok("[]")

  defp response(%{executable: "podman", args: ["load", "--input", _path]}),
    do: ok("Loaded image: localhost/native-fixture:latest\n")

  defp response(%{executable: "podman", args: ["image", "inspect" | _]}),
    do: ok(Jason.encode!([%{"Id" => @image_id}]))

  defp response(%{executable: "podman", args: ["run", "--detach" | _]}),
    do: ok("candidate-container-id\n")

  defp response(%{executable: "podman", args: ["container", "inspect" | _]}) do
    ok(
      Jason.encode!([
        %{
          "Image" => @image_id,
          "State" => %{"Running" => true},
          "Config" => %{
            "Labels" => %{
              "io.nixploy.managed" => "true",
              "io.nixploy.project" => "native-fixture",
              "io.nixploy.target" => "production",
              "io.nixploy.slot" => "blue",
              "io.nixploy.deployment_input" => "input-id"
            }
          }
        }
      ])
    )
  end

  defp response(%{executable: "curl", args: args}) do
    url = List.last(args)

    cond do
      String.contains?(url, "nixploy-route-") -> ok("null\n404")
      String.contains?(url, "/upstreams") -> ok("[{\"dial\":\"127.0.0.1:18080\"}]\n200")
      String.starts_with?(url, "http://127.0.0.1:18080/health") -> ok("")
      "POST" in args -> ok("")
    end
  end

  defp operation do
    snapshot = snapshot()

    input = %DeploymentInput{
      id: "input-id",
      state: :staged,
      store_path: @store_path,
      nar_hash: @nar_hash,
      selected_target: "production",
      derived_snapshot: snapshot,
      configuration_digest: LocalStoreInput.digest(snapshot)
    }

    %NativeDeployment{
      id: "operation-id",
      project: "native-fixture",
      target: "production",
      deployment_input: input
    }
  end

  defp snapshot do
    {:ok, source} =
      LocalStoreInput.probe(@store_path,
        path_exists?: fn _path -> true end,
        execute: fn
          %{args: ["path-info" | _]}, _opts -> ok(path_info_json())
          %{args: ["eval" | _]}, _opts -> ok(Jason.encode!(config()))
        end
      )

    {:ok, _target, snapshot} = LocalStoreInput.select_target(source, "production")
    snapshot
  end

  defp config do
    %{
      "__schema" => "v0.2",
      "project" => "native-fixture",
      "targets" => %{
        "production" => %{
          "image" => "fixtureImage",
          "run" => %{
            "command" => nil,
            "environment" => %{"PORT" => "{port}"},
            "network" => "host",
            "ports" => [],
            "preStart" => []
          },
          "secrets" => %{},
          "web" => %{
            "domain" => "native-fixture.invalid",
            "healthPath" => "/health",
            "slots" => %{"blue" => 18_080, "green" => 18_081}
          }
        }
      }
    }
  end

  defp path_info_json, do: Jason.encode!(%{@store_path => %{"narHash" => @nar_hash}})

  defp ok(output),
    do: {:ok, %Result{exit_status: 0, output_tail: output, output_truncated?: false}}

  defp health_command?(command) do
    command.executable == "curl" and
      Enum.any?(command.args, &String.starts_with?(&1, "http://127.0.0.1:18080/health"))
  end

  defp derived_prefix(project, target) do
    identity = :crypto.hash(:sha256, project <> <<0>> <> target) |> Base.encode16(case: :lower)
    "nixploy-#{project}-#{String.slice(identity, 0, 10)}-#{target}"
  end

  defp drain_messages(messages) do
    receive do
      message -> drain_messages([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp drain_commands(commands) do
    receive do
      {:command, command} -> drain_commands([command | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end
end
