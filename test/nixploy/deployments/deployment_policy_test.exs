defmodule Nixploy.Deployments.DeploymentPolicyTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.{DeploymentInput, DeploymentPolicy, NativeDeployment}
  alias Nixploy.Execution.Result

  test "maps canonical immutable input into a capability-free bounded Wasmtime invocation" do
    parent = self()

    execute = fn command, _opts ->
      send(parent, {:command, command})
      {:ok, %Result{exit_status: 0, output_tail: "warning\n1\n", output_truncated?: false}}
    end

    assert {:ok, decision} =
             DeploymentPolicy.evaluate(deployment(),
               execute: execute,
               component: "/nix/store/policy/deployment-policy.wasm",
               wasmtime: "/nix/store/wasmtime/bin/wasmtime",
               read: fn _path -> {:ok, "wasm-component"} end,
               runtime_mode: :remote_control_plane,
               mode: :enforce,
               plan: plan()
             )

    assert decision.allow?
    assert decision.mode == :enforce
    assert byte_size(decision.payload_digest) == 64
    assert byte_size(decision.component_digest) == 64

    assert_receive {:command, command}
    assert command.timeout == 1_000
    assert command.max_output_bytes == 4_096

    assert command.args == [
             "run",
             "-W",
             "fuel=100000",
             "-W",
             "max-memory-size=16777216",
             "-W",
             "timeout=250ms",
             "--invoke",
             "decide",
             "/nix/store/policy/deployment-policy.wasm",
             "1",
             "1",
             "1",
             "1",
             "1",
             "1"
           ]

    refute "--dir" in command.args
    refute "--env" in command.args
  end

  test "records deny evidence in shadow mode and fails closed in enforce mode" do
    execute = fn _command, _opts ->
      {:ok, %Result{exit_status: 0, output_tail: "0\n", output_truncated?: false}}
    end

    opts = [
      execute: execute,
      component: "/nix/store/policy/deployment-policy.wasm",
      wasmtime: "/nix/store/wasmtime/bin/wasmtime",
      read: fn _path -> {:ok, "wasm-component"} end,
      runtime_mode: :local_recovery,
      plan: plan()
    ]

    assert {:ok, %{allow?: false, mode: :shadow, code: "v1_boundary_denied"}} =
             DeploymentPolicy.evaluate(deployment(), Keyword.put(opts, :mode, :shadow))

    assert {:error, {:policy_denied, %{allow?: false, mode: :enforce}}} =
             DeploymentPolicy.evaluate(deployment(), Keyword.put(opts, :mode, :enforce))
  end

  test "fails closed on traps, overflow, malformed output, and unavailable component" do
    base = [
      component: "/nix/store/policy/deployment-policy.wasm",
      wasmtime: "/nix/store/wasmtime/bin/wasmtime",
      read: fn _path -> {:ok, "wasm-component"} end,
      runtime_mode: :remote_control_plane,
      mode: :enforce,
      plan: plan()
    ]

    assert {:error, {:policy_runtime_failed, 134}} =
             DeploymentPolicy.evaluate(
               deployment(),
               Keyword.put(base, :execute, result(134, "trap", false))
             )

    assert {:error, :policy_output_too_large} =
             DeploymentPolicy.evaluate(
               deployment(),
               Keyword.put(base, :execute, result(0, "1", true))
             )

    assert {:error, :policy_output_invalid} =
             DeploymentPolicy.evaluate(
               deployment(),
               Keyword.put(base, :execute, result(0, "maybe", false))
             )

    assert {:error, :policy_component_unavailable} =
             DeploymentPolicy.evaluate(
               deployment(),
               base
               |> Keyword.put(:execute, result(0, "1", false))
               |> Keyword.put(:read, fn _path -> {:error, :enoent} end)
             )

    assert {:error, {:policy_runtime_failed, :timeout}} =
             DeploymentPolicy.evaluate(
               deployment(),
               Keyword.put(base, :execute, fn _command, _opts -> {:error, :timeout} end)
             )

    assert {:error, {:policy_runtime_failed, {:executable_not_found, _path}}} =
             DeploymentPolicy.evaluate(
               deployment(),
               Keyword.put(base, :execute, fn command, _opts ->
                 {:error, {:executable_not_found, command.executable}}
               end)
             )
  end

  test "fresh immutable plan is part of the deterministic policy contract" do
    parent = self()

    execute = fn command, _opts ->
      send(parent, command.args)
      {:ok, %Result{exit_status: 0, output_tail: "0\n", output_truncated?: false}}
    end

    bad_plan = put_in(plan(), ["resource_key"], "nixploy-wrong")

    assert {:error, {:policy_denied, decision}} =
             DeploymentPolicy.evaluate(deployment(),
               execute: execute,
               component: "/nix/store/policy/deployment-policy.wasm",
               wasmtime: "/nix/store/wasmtime/bin/wasmtime",
               read: fn _path -> {:ok, "wasm-component"} end,
               runtime_mode: :remote_control_plane,
               mode: :enforce,
               plan: bad_plan
             )

    assert decision.contract_version == "nixploy.policy/v1"
    assert byte_size(decision.plan_digest) == 64
    assert decision.findings == ["v1_boundary_denied"]
    assert is_integer(decision.duration_ms)
    assert_receive args
    assert List.last(args) == "0"
  end

  defp result(status, output, truncated?) do
    fn _command, _opts ->
      {:ok,
       %Result{
         exit_status: status,
         output_tail: output,
         output_truncated?: truncated?
       }}
    end
  end

  defp plan do
    %{
      "schema" => "nixploy.plan/v1",
      "operation_id" => deployment().id,
      "resource_key" => "nixploy-fixture-bab0990cab-production",
      "project" => "fixture",
      "target" => "production",
      "intended_effects" => ["build_image", "load_remote_image"]
    }
  end

  defp deployment do
    %NativeDeployment{
      id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      project: "fixture",
      target: "production",
      deployment_input: %DeploymentInput{
        input_kind: :git_main,
        store_path: "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source",
        source_revision: String.duplicate("b", 40),
        configuration_digest: String.duplicate("c", 64)
      }
    }
  end
end
