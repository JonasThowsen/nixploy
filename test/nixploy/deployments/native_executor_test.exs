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

  test "runs fixed flake-declared pre-start argv before candidate startup" do
    parent = self()
    config = config(pre_start: [["/bin/fixture-pre-start", "--migrate"]])
    operation = operation([], config)

    execute = fn command, opts ->
      send(parent, {:command, command, opts})

      case {command.executable, command.args} do
        {"nix", ["eval" | _]} -> ok(Jason.encode!(config))
        {"podman", ["run", "--rm" | _]} -> ok("pre-start complete\n")
        _other -> response(command)
      end
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

    assert {:stage, :pre_starting, "Running flake-declared pre-start actions",
            %{metadata: %{action_count: 1}}} in messages

    commands = for {:command, command, _opts} <- messages, do: command
    pre_start_index = Enum.find_index(commands, &match?(["run", "--rm" | _], &1.args))
    candidate_index = Enum.find_index(commands, &match?(["run", "--detach" | _], &1.args))

    assert is_integer(pre_start_index)
    assert pre_start_index < candidate_index

    pre_start = Enum.at(commands, pre_start_index)
    assert pre_start.executable == "podman"
    assert pre_start.timeout == 900_000
    assert pre_start.max_output_bytes == 65_536
    assert Enum.take(pre_start.args, 2) == ["run", "--rm"]
    assert Enum.take(pre_start.args, -2) == ["/bin/fixture-pre-start", "--migrate"]
    assert "PORT=18080" in pre_start.args
    assert "host" in pre_start.args
    refute "--publish" in pre_start.args
    refute Enum.any?(commands, &(&1.executable in ["sh", "bash"]))
  end

  test "resolves worker credentials and injects operation-scoped Podman secrets" do
    parent = self()
    secret_value = "worker-only-secret-value"

    config =
      config(
        pre_start: [["/bin/fixture-pre-start"]],
        secrets: %{"app" => "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-secret.env"}
      )

    resolver = fn references, opts ->
      send(parent, {:credential_resolver, references, opts})
      {:ok, [%{name: "FIXTURE_TOKEN", value: secret_value}]}
    end

    execute = fn command, opts ->
      send(parent, {:command, command, opts})

      case {command.executable, command.args} do
        {"nix", ["eval" | _]} -> ok(Jason.encode!(config))
        {"podman", ["secret", "create" | _]} -> ok("secret-id\n")
        {"podman", ["run", "--rm" | _]} -> ok("pre-start complete\n")
        _other -> response(command)
      end
    end

    stage = fn state, message, attrs ->
      send(parent, {:stage, state, message, attrs})
      :ok
    end

    assert :ok =
             NativeExecutor.deploy(operation([], config),
               execute: execute,
               resolve_credentials: resolver,
               path_exists?: fn _path -> true end,
               stage: stage,
               cancelled?: fn -> false end,
               health_attempts: 1,
               health_delay_ms: 0
             )

    messages = drain_messages([])

    assert {:credential_resolver,
            %{"app" => "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-secret.env"},
            [execute: resolver_execute, cancelled?: resolver_cancelled?]} =
             Enum.find(messages, &match?({:credential_resolver, _, _}, &1))

    assert is_function(resolver_execute, 2)
    refute resolver_cancelled?.()

    assert {:stage, :installing_credentials, "Resolving worker-only project credentials",
            %{metadata: %{credential_file_count: 1}}} in messages

    commands = for {:command, command, _opts} <- messages, do: command
    secret_create = Enum.find(commands, &match?(["secret", "create" | _], &1.args))
    pre_start = Enum.find(commands, &match?(["run", "--rm" | _], &1.args))
    candidate = Enum.find(commands, &match?(["run", "--detach" | _], &1.args))

    assert secret_create.stdin == secret_value
    assert secret_create.redact == [secret_value]
    refute secret_value in secret_create.args
    refute secret_value in Map.values(secret_create.env)
    assert List.last(secret_create.args) == "-"
    assert "--label" in secret_create.args

    secret_mount =
      Enum.find(pre_start.args, &String.starts_with?(&1, "source=nixploy-native-fixture-"))

    assert String.ends_with?(secret_mount, ",type=env,target=FIXTURE_TOKEN")
    assert secret_mount in candidate.args
    assert pre_start.redact == [secret_value]
    assert candidate.redact == [secret_value]

    secret_index = Enum.find_index(commands, &(&1 == secret_create))
    pre_start_index = Enum.find_index(commands, &(&1 == pre_start))
    candidate_index = Enum.find_index(commands, &(&1 == candidate))
    assert secret_index < pre_start_index
    assert pre_start_index < candidate_index
  end

  test "pre-start failure preserves the healthy routed slot and never starts a candidate" do
    prefix = "nixploy-native-fixture-existing-production"
    active = active_green(prefix)
    config = config(pre_start: [["/bin/fixture-pre-start"]])

    execute = fn command, _opts ->
      send(self(), {:command, command})

      case {command.executable, command.args} do
        {"nix", ["path-info" | _]} ->
          ok(path_info_json())

        {"nix", ["eval" | _]} ->
          ok(Jason.encode!(config))

        {"nix", ["build" | _]} ->
          ok(Jason.encode!([%{"outputs" => %{"out" => "/nix/store/image-tar"}}]))

        {"podman", ["ps", "-a", "--format", "json"]} ->
          ok(Jason.encode!([active]))

        {"podman", ["load" | _]} ->
          ok("Loaded image: localhost/native-fixture:latest\n")

        {"podman", ["image", "inspect" | _]} ->
          ok(Jason.encode!([%{"Id" => @image_id}]))

        {"podman", ["rm" | _]} ->
          ok("")

        {"podman", ["run", "--rm" | _]} ->
          command_error(17, "migration rejected")

        {"curl", args} ->
          existing_route_response(args, prefix)
      end
    end

    assert {:error,
            {:pre_start_failed, 1, 1,
             {:pre_start_action, :command_failed, 17, "migration rejected"}}} =
             NativeExecutor.deploy(operation([], config),
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end
             )

    commands = drain_commands([])
    refute Enum.any?(commands, &match?(["run", "--detach" | _], &1.args))
    refute Enum.any?(commands, &(&1.executable == "curl" and "PATCH" in &1.args))
    refute Enum.any?(commands, &match?(["stop" | _], &1.args))
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

            String.starts_with?(url, "http://127.0.0.1:18081/health") ->
              ok("")

            String.starts_with?(url, "http://127.0.0.1:18080/health") ->
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

  test "build failure preserves the healthy routed slot" do
    prefix = "nixploy-native-fixture-existing-production"
    active = active_green(prefix)

    execute = fn command, _opts ->
      send(self(), {:command, command})

      case {command.executable, command.args} do
        {"nix", ["path-info" | _]} -> ok(path_info_json())
        {"nix", ["eval" | _]} -> ok(Jason.encode!(config()))
        {"nix", ["build" | _]} -> command_error(1, "injected build failure")
        {"podman", ["ps", "-a", "--format", "json"]} -> ok(Jason.encode!([active]))
        {"curl", args} -> existing_route_response(args, prefix)
      end
    end

    assert {:error, {:nix_build, :command_failed, 1, "injected build failure"}} =
             NativeExecutor.deploy(operation(),
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end
             )

    commands = drain_commands([])
    refute Enum.any?(commands, &(&1.executable == "curl" and "PATCH" in &1.args))
    refute Enum.any?(commands, &match?(["stop" | _], &1.args))
  end

  test "candidate start failure preserves the healthy routed slot" do
    prefix = "nixploy-native-fixture-existing-production"
    active = active_green(prefix)

    execute = fn command, _opts ->
      send(self(), {:command, command})

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
          command_error(125, "injected start failure")

        {"curl", args} ->
          existing_route_response(args, prefix)
      end
    end

    assert {:error, {:podman_run, :command_failed, 125, "injected start failure"}} =
             NativeExecutor.deploy(operation(),
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end
             )

    commands = drain_commands([])
    refute Enum.any?(commands, &(&1.executable == "curl" and "PATCH" in &1.args))
    refute Enum.any?(commands, &match?(["stop" | _], &1.args))
  end

  test "Caddy mutation failure reads back the unchanged old upstream" do
    prefix = "nixploy-native-fixture-existing-production"
    active = active_green(prefix)

    execute = fn command, _opts ->
      send(self(), {:command, command})

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
          if "PATCH" in args,
            do: command_error(22, "injected Caddy failure"),
            else: existing_route_response(args, prefix)
      end
    end

    assert {:error,
            {:caddy_switch_failed_previous_preserved,
             {:caddy_mutation, :command_failed, 22, "injected Caddy failure"}, "127.0.0.1:18081"}} =
             NativeExecutor.deploy(operation(),
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end,
               health_attempts: 1,
               health_delay_ms: 0
             )

    commands = drain_commands([])
    assert Enum.count(commands, &(&1.executable == "curl" and "PATCH" in &1.args)) == 1

    assert Enum.count(commands, fn command ->
             command.executable == "curl" and
               Enum.any?(command.args, &String.ends_with?(&1, "/upstreams"))
           end) >= 2

    refute Enum.any?(commands, &match?(["stop" | _], &1.args))
  end

  test "post-switch verification failure restores and reads back the old upstream" do
    prefix = "nixploy-native-fixture-existing-production"
    active = active_green(prefix)
    {:ok, state} = Agent.start_link(fn -> %{upstream: 18_081, candidate_healths: 0} end)

    execute = fn command, _opts ->
      send(self(), {:command, command})

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
          if "PATCH" in args do
            body = Enum.at(args, Enum.find_index(args, &(&1 == "--data-binary")) + 1)
            port = if String.contains?(body, "18080"), do: 18_080, else: 18_081
            Agent.update(state, &%{&1 | upstream: port})
            ok("")
          else
            url = List.last(args)

            cond do
              String.contains?(url, "nixploy-route-") ->
                ok(
                  Jason.encode!(%{"match" => [%{"host" => ["native-fixture.invalid"]}]}) <>
                    "\n200"
                )

              String.contains?(url, "/upstreams") ->
                port = Agent.get(state, & &1.upstream)
                ok("[{\"dial\":\"127.0.0.1:#{port}\"}]\n200")

              String.starts_with?(url, "http://127.0.0.1:18081/health") ->
                ok("")

              String.starts_with?(url, "http://127.0.0.1:18080/health") ->
                count =
                  Agent.get_and_update(
                    state,
                    &{&1.candidate_healths, %{&1 | candidate_healths: &1.candidate_healths + 1}}
                  )

                if count == 0,
                  do: ok(""),
                  else: command_error(22, "injected readback health failure")
            end
          end
      end
    end

    assert {:error,
            {:caddy_switch_failed_previous_preserved,
             {:candidate_health, :command_failed, 22, "injected readback health failure"},
             "127.0.0.1:18081"}} =
             NativeExecutor.deploy(operation(),
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end,
               health_attempts: 1,
               health_delay_ms: 0
             )

    assert Agent.get(state, & &1.upstream) == 18_081
    commands = drain_commands([])
    assert Enum.count(commands, &(&1.executable == "curl" and "PATCH" in &1.args)) == 2
    refute Enum.any?(commands, &match?(["stop" | _], &1.args))
  end

  test "rollback requires the exact persisted inactive slot and image ID before mutation" do
    prefix = "nixploy-native-fixture-existing-production"
    active = active_green(prefix)

    execute = fn command, _opts ->
      send(self(), {:command, command})

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

        {"curl", args} ->
          existing_route_response(args, prefix)
      end
    end

    rollback =
      operation(
        operation_kind: :rollback,
        expected_slot: "blue",
        expected_image_id: "sha256:different-image"
      )

    assert {:error, :rollback_image_mismatch} =
             NativeExecutor.deploy(rollback,
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end
             )

    commands = drain_commands([])
    refute Enum.any?(commands, &match?(["rm" | _], &1.args))
    refute Enum.any?(commands, &match?(["run" | _], &1.args))
    refute Enum.any?(commands, &(&1.executable == "curl" and "PATCH" in &1.args))

    wrong_slot =
      operation(
        operation_kind: :rollback,
        expected_slot: "green",
        expected_image_id: @image_id
      )

    assert {:error, :rollback_target_not_inactive} =
             NativeExecutor.deploy(wrong_slot,
               execute: execute,
               path_exists?: fn _path -> true end,
               stage: fn _state, _message, _attrs -> :ok end,
               cancelled?: fn -> false end
             )
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

  defp operation(attrs \\ [], config \\ config()) do
    snapshot = snapshot(config)

    input = %DeploymentInput{
      id: "input-id",
      state: :staged,
      store_path: @store_path,
      nar_hash: @nar_hash,
      selected_target: "production",
      derived_snapshot: snapshot,
      configuration_digest: LocalStoreInput.digest(snapshot)
    }

    operation = %NativeDeployment{
      id: "operation-id",
      project: "native-fixture",
      target: "production",
      deployment_input: input
    }

    struct!(operation, attrs)
  end

  defp snapshot(config) do
    {:ok, source} =
      LocalStoreInput.probe(@store_path,
        path_exists?: fn _path -> true end,
        execute: fn
          %{args: ["path-info" | _]}, _opts -> ok(path_info_json())
          %{args: ["eval" | _]}, _opts -> ok(Jason.encode!(config))
        end
      )

    {:ok, _target, snapshot} = LocalStoreInput.select_target(source, "production")
    snapshot
  end

  defp config(opts \\ []) do
    pre_start = Keyword.get(opts, :pre_start, [])
    secrets = Keyword.get(opts, :secrets, %{})

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
            "preStart" => pre_start
          },
          "secrets" => secrets,
          "web" => %{
            "domain" => "native-fixture.invalid",
            "healthPath" => "/health",
            "slots" => %{"blue" => 18_080, "green" => 18_081}
          }
        }
      }
    }
  end

  defp active_green(prefix) do
    %{
      "Names" => ["#{prefix}-green"],
      "State" => "running",
      "Labels" => %{
        "io.nixploy.managed" => "true",
        "io.nixploy.project" => "native-fixture",
        "io.nixploy.target" => "production"
      }
    }
  end

  defp existing_route_response(args, prefix) do
    url = List.last(args)

    cond do
      String.contains?(url, "nixploy-route-#{prefix}") ->
        ok(Jason.encode!(%{"match" => [%{"host" => ["native-fixture.invalid"]}]}) <> "\n200")

      String.contains?(url, "/upstreams") ->
        ok("[{\"dial\":\"127.0.0.1:18081\"}]\n200")

      String.starts_with?(url, "http://127.0.0.1:18081/health") ->
        ok("")

      String.starts_with?(url, "http://127.0.0.1:18080/health") ->
        ok("")
    end
  end

  defp path_info_json, do: Jason.encode!(%{@store_path => %{"narHash" => @nar_hash}})

  defp command_error(status, output),
    do: {:ok, %Result{exit_status: status, output_tail: output, output_truncated?: false}}

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
