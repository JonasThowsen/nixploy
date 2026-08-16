defmodule Nixploy.Deployments.DeploymentPolicy do
  @moduledoc "Runs the pinned capability-free MoonBit policy under bounded Wasmtime."

  alias Nixploy.Deployments.{NativeDeployment, ResourceIdentity}
  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @timeout 1_000
  @max_output 4_096
  @fuel 100_000
  @memory_bytes 16_777_216
  @revision ~r/^[0-9a-f]{40}$/
  @digest ~r/^[0-9a-f]{64}$/

  def evaluate(%NativeDeployment{} = deployment, opts \\ []) do
    input = deployment.deployment_input
    resource_key = ResourceIdentity.derive!(deployment.project, deployment.target)

    operation = Keyword.get(opts, :operation, :deploy)
    fresh_plan = Keyword.get(opts, :plan)
    plan_digest = if is_map(fresh_plan), do: fresh_plan |> canonical_json() |> sha256()

    payload = %{
      "configuration_digest" => input.configuration_digest,
      "operation" => Atom.to_string(operation),
      "operation_id" => deployment.id,
      "plan_digest" => plan_digest,
      "resource_key" => resource_key,
      "runtime_mode" => Atom.to_string(runtime_mode(opts)),
      "source_kind" => Atom.to_string(input.input_kind),
      "source_revision" => input.source_revision,
      "store_path" => input.store_path,
      "target" => deployment.target
    }

    canonical = canonical_json(payload)
    payload_digest = sha256(canonical)
    component = Keyword.get_lazy(opts, :component, &component!/0)
    wasmtime = Keyword.get_lazy(opts, :wasmtime, &wasmtime!/0)
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    mode = Keyword.get(opts, :mode, policy_mode())

    flags = [
      case operation do
        :deploy -> 1
        :task -> 2
        _operation -> 0
      end,
      if(payload["runtime_mode"] == "remote_control_plane", do: 1, else: 0),
      if(trusted_source?(input), do: 1, else: 0),
      if(resource_key_valid?(resource_key), do: 1, else: 0),
      if(immutable_identity_valid?(payload), do: 1, else: 0),
      if(plan_valid?(operation, fresh_plan, deployment, resource_key), do: 1, else: 0)
    ]

    command = %Command{
      executable: wasmtime,
      args: [
        "run",
        "-W",
        "fuel=#{@fuel}",
        "-W",
        "max-memory-size=#{@memory_bytes}",
        "-W",
        "timeout=250ms",
        "--invoke",
        "decide",
        component
        | Enum.map(flags, &Integer.to_string/1)
      ],
      timeout: @timeout,
      max_output_bytes: @max_output
    }

    started_at = System.monotonic_time()

    with :ok <- validate_mode(mode),
         :ok <- validate_packaged_path(component, "policy component"),
         :ok <- validate_packaged_path(wasmtime, "Wasmtime executable"),
         {:ok, component_digest} <- component_digest(component, opts),
         {:ok, result} <- run_policy(execute, command),
         :ok <- bounded_success(result),
         {:ok, allow?} <- parse_decision(result.output_tail) do
      decision = %{
        allow?: allow?,
        mode: mode,
        contract_version: "nixploy.policy/v1",
        payload_digest: payload_digest,
        plan_digest: plan_digest,
        component_digest: component_digest,
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond),
        findings: if(allow?, do: [], else: ["v1_boundary_denied"]),
        code: if(allow?, do: "allowed", else: "v1_boundary_denied")
      }

      if allow? or mode == :shadow,
        do: {:ok, decision},
        else: {:error, {:policy_denied, decision}}
    end
  end

  defp run_policy(execute, command) do
    case execute.(command, []) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:policy_runtime_failed, reason}}
    end
  end

  defp bounded_success(%{output_truncated?: true}), do: {:error, :policy_output_too_large}
  defp bounded_success(%{exit_status: 0}), do: :ok
  defp bounded_success(%{exit_status: status}), do: {:error, {:policy_runtime_failed, status}}

  defp parse_decision(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      "1" -> {:ok, true}
      "0" -> {:ok, false}
      _other -> {:error, :policy_output_invalid}
    end
  end

  defp component_digest(component, opts) do
    read = Keyword.get(opts, :read, &File.read/1)

    case read.(component) do
      {:ok, bytes} when byte_size(bytes) <= 1_048_576 -> {:ok, sha256(bytes)}
      {:ok, _bytes} -> {:error, :policy_component_too_large}
      {:error, _reason} -> {:error, :policy_component_unavailable}
    end
  end

  defp trusted_source?(%{input_kind: :git_main}), do: true

  defp trusted_source?(%{
         input_kind: :local_store,
         registration_channel: :ci,
         source_repository: repository,
         source_revision: revision,
         nar_hash: nar_hash
       }) do
    is_binary(repository) and repository != "" and is_binary(revision) and
      Regex.match?(@revision, revision) and is_binary(nar_hash) and
      String.starts_with?(nar_hash, "sha256-")
  end

  defp trusted_source?(_input), do: false

  defp immutable_identity_valid?(payload) do
    is_binary(payload["store_path"]) and String.starts_with?(payload["store_path"], "/nix/store/") and
      is_binary(payload["source_revision"]) and
      Regex.match?(@revision, payload["source_revision"]) and
      is_binary(payload["configuration_digest"]) and
      Regex.match?(@digest, payload["configuration_digest"])
  end

  defp plan_valid?(:task, nil, _deployment, _resource_key), do: true

  defp plan_valid?(:deploy, plan, deployment, resource_key) when is_map(plan) do
    plan["schema"] == "nixploy.plan/v1" and plan["operation_id"] == deployment.id and
      plan["resource_key"] == resource_key and plan["project"] == deployment.project and
      plan["target"] == deployment.target and is_list(plan["intended_effects"])
  end

  defp plan_valid?(_operation, _plan, _deployment, _resource_key), do: false

  defp resource_key_valid?(key), do: Regex.match?(~r/^nixploy-[a-z0-9][a-z0-9_-]{0,126}$/, key)

  defp validate_mode(mode) when mode in [:shadow, :enforce], do: :ok
  defp validate_mode(_mode), do: {:error, :policy_mode_invalid}

  defp validate_packaged_path(path, _label)
       when is_binary(path) and byte_size(path) <= 4_096 and
              binary_part(path, 0, min(byte_size(path), 11)) == "/nix/store/",
       do: :ok

  defp validate_packaged_path(_path, label), do: {:error, {:policy_path_invalid, label}}

  defp runtime_mode(opts), do: Keyword.get(opts, :runtime_mode, Nixploy.RuntimeMode.current())
  defp policy_mode, do: Application.get_env(:nixploy, :deployment_policy_mode, :enforce)
  defp component!, do: Application.fetch_env!(:nixploy, :deployment_policy_component)
  defp wasmtime!, do: Application.fetch_env!(:nixploy, :wasmtime_executable)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, nested} ->
      Jason.encode!(key) <> ":" <> canonical_json(nested)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value), do: Jason.encode!(value)
end
