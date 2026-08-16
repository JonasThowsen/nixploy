defmodule Nixploy.Deployments.ConfigProbe do
  @moduledoc "Validates the committed flake target against the immutable control-plane spec."

  alias Nixploy.Deployments.Spec
  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @timeout :timer.minutes(5)
  @schema "v0.2"

  def validate(deployment, workspace, opts \\ []) do
    executable = Application.get_env(:nixploy, :nix_executable, "nix")

    command = %Command{
      executable: executable,
      args: ["eval", "--json", "--no-write-lock-file", ".#nixploy"],
      cd: workspace,
      timeout: @timeout
    }

    with {:ok, output} <- run(command, opts),
         {:ok, config} <- decode(output) do
      validate_config(config, deployment.service_snapshot)
    end
  end

  @doc false
  def validate_config(config, snapshot) do
    with :ok <- validate_schema(config),
         {:ok, target} <- fetch_target(config, Spec.target_name(snapshot)),
         :ok <- validate_target(target, snapshot) do
      {:ok, digest(target)}
    end
  end

  defp run(command, opts) do
    case Execution.run(command, opts) do
      {:ok, %{exit_status: 0, output_tail: output}} -> {:ok, output}
      {:ok, result} -> {:error, {:nix_eval_failed, result.exit_status, result.output_tail}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _value} -> {:error, :nixploy_config_not_an_object}
      {:error, error} -> {:error, {:invalid_nixploy_config_json, Exception.message(error)}}
    end
  end

  defp validate_schema(%{"__schema" => @schema}), do: :ok

  defp validate_schema(%{"__schema" => schema}),
    do: {:error, {:unsupported_config_schema, schema}}

  defp validate_schema(_config), do: {:error, :config_schema_missing}

  defp fetch_target(%{"targets" => targets}, name) when is_map(targets) do
    case targets[name] do
      target when is_map(target) -> {:ok, target}
      _missing -> {:error, {:flake_target_missing, name}}
    end
  end

  defp fetch_target(_config, name), do: {:error, {:flake_target_missing, name}}

  defp validate_target(target, snapshot) do
    expected = %{
      "image" => get_in(snapshot, ["service", "flake_output"]),
      "ip" => get_in(snapshot, ["target", "host"]),
      "port" => get_in(snapshot, ["target", "ssh_port"]),
      "user" => get_in(snapshot, ["target", "ssh_user"]),
      "web.domain" => get_in(snapshot, ["service", "domain"]),
      "web.healthPath" => get_in(snapshot, ["service", "health_path"])
    }

    actual = %{
      "image" => target["image"],
      "ip" => target["ip"],
      "port" => target["port"],
      "user" => target["user"],
      "web.domain" => get_in(target, ["web", "domain"]),
      "web.healthPath" => get_in(target, ["web", "healthPath"])
    }

    mismatches =
      expected
      |> Enum.flat_map(fn {field, value} ->
        if actual[field] == value,
          do: [],
          else: [%{field: field, expected: value, actual: actual[field]}]
      end)
      |> Enum.sort_by(& &1.field)

    if mismatches == [], do: :ok, else: {:error, {:configuration_mismatch, mismatches}}
  end

  defp digest(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, nested} -> {key, canonical(nested)} end)
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
