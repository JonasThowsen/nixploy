defmodule Nixploy.Deployments.LocalStoreInput do
  @moduledoc "Verifies and derives deployment input from one immutable local Nix store source."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  defmodule Source do
    @moduledoc false
    defstruct [:store_path, :nar_hash, :project, targets: %{}]

    @type t :: %__MODULE__{
            store_path: String.t(),
            nar_hash: String.t(),
            project: String.t(),
            targets: %{String.t() => map()}
          }
  end

  @path_info_timeout :timer.seconds(30)
  @eval_timeout :timer.minutes(5)
  @max_json_bytes 1_048_576
  @schema "v0.2"
  @max_path_bytes 4_096
  @max_value_bytes 4_096
  @max_pre_start_actions 32
  @max_argv_items 128
  @nar_hash ~r/^[A-Za-z0-9][A-Za-z0-9+\/_=.~:-]*$/

  @spec probe(String.t(), keyword()) :: {:ok, Source.t()} | {:error, term()}
  def probe(store_path, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    path_exists? = Keyword.get(opts, :path_exists?, &File.dir?/1)

    with {:ok, store_path} <- validate_store_path(store_path, path_exists?),
         {:ok, nar_hash} <- path_info(store_path, execute, opts),
         {:ok, config} <- evaluate(store_path, execute, opts),
         {:ok, project, targets} <- normalize_config(config) do
      {:ok,
       %Source{
         store_path: store_path,
         nar_hash: nar_hash,
         project: project,
         targets: targets
       }}
    end
  end

  @doc false
  def validate_store_path(store_path, path_exists? \\ &File.dir?/1)

  def validate_store_path(store_path, path_exists?) when is_binary(store_path) do
    trimmed = String.trim(store_path)

    cond do
      trimmed == "" ->
        {:error, :store_path_required}

      byte_size(trimmed) > @max_path_bytes ->
        {:error, :store_path_too_long}

      trimmed != store_path ->
        {:error, :store_path_not_canonical}

      Path.type(trimmed) != :absolute ->
        {:error, :store_path_not_absolute}

      Path.expand(trimmed) != trimmed or Path.dirname(trimmed) != "/nix/store" ->
        {:error, :store_path_outside_nix_store}

      not path_exists?.(trimmed) ->
        {:error, :store_path_not_found}

      true ->
        {:ok, trimmed}
    end
  end

  def validate_store_path(_store_path, _path_exists?), do: {:error, :store_path_required}

  @doc false
  def parse_path_info(output, store_path) when is_binary(output) do
    with {:ok, decoded} <- decode_json(output, :path_info),
         {:ok, info} <- exact_path_info(decoded, store_path),
         {:ok, nar_hash} <- extract_nar_hash(info) do
      {:ok, nar_hash}
    end
  end

  @doc false
  def parse_config(output) when is_binary(output), do: decode_json(output, :nixploy_config)

  @doc false
  def normalize_config(%{"__schema" => @schema, "project" => project, "targets" => targets})
      when is_map(targets) do
    with {:ok, project} <- required_string(project, :project),
         false <- map_size(targets) == 0,
         {:ok, normalized_targets} <- normalize_targets(targets) do
      {:ok, project, normalized_targets}
    else
      true -> {:error, :flake_targets_missing}
      {:error, _reason} = error -> error
    end
  end

  def normalize_config(%{"__schema" => @schema}), do: {:error, :flake_project_or_targets_missing}

  def normalize_config(%{"__schema" => schema}),
    do: {:error, {:unsupported_config_schema, schema}}

  def normalize_config(config) when is_map(config), do: {:error, :config_schema_missing}
  def normalize_config(_config), do: {:error, :nixploy_config_not_an_object}

  @doc false
  def select_target(%Source{project: project, targets: targets}, target_name) do
    target_name = normalize_target_name(target_name)

    case {target_name, Map.keys(targets) |> Enum.sort()} do
      {nil, []} ->
        {:error, :flake_targets_missing}

      {nil, [only_target]} ->
        selected(project, targets, only_target)

      {nil, target_names} ->
        {:error, {:ambiguous_flake_targets, target_names}}

      {name, _target_names} ->
        selected(project, targets, name)
    end
  end

  @doc false
  def digest(value) do
    value
    |> canonical_json()
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def failure(reason) do
    %{"code" => failure_code(reason), "message" => error_message(reason)}
  end

  def error_message(:store_path_required), do: "Enter an immutable Nix store source path."
  def error_message(:store_path_too_long), do: "The Nix store path exceeds the 4096-byte limit."

  def error_message(:store_path_not_canonical),
    do: "Use the canonical store path without surrounding whitespace or relative segments."

  def error_message(:store_path_not_absolute), do: "The source path must be absolute."

  def error_message(:store_path_outside_nix_store),
    do: "The source must be a direct path under /nix/store."

  def error_message(:store_path_not_found), do: "That Nix store source does not exist."
  def error_message(:path_info_output_too_large), do: "Nix path verification exceeded 1 MiB."
  def error_message(:eval_output_too_large), do: "Nix configuration evaluation exceeded 1 MiB."
  def error_message(:path_info_timeout), do: "Nix path verification timed out after 30 seconds."
  def error_message(:eval_timeout), do: "Nix configuration evaluation timed out after 5 minutes."

  def error_message({:path_info_failed, status, output}),
    do: "Nix path verification exited with status #{status}: #{safe_tail(output)}"

  def error_message({:eval_failed, status, output}),
    do: "Nix configuration evaluation exited with status #{status}: #{safe_tail(output)}"

  def error_message({:path_info_command_failed, reason}),
    do: "Nix path verification failed: #{command_error(reason)}"

  def error_message({:eval_command_failed, reason}),
    do: "Nix configuration evaluation failed: #{command_error(reason)}"

  def error_message({:invalid_path_info_json, _detail}),
    do: "Nix path verification returned malformed JSON."

  def error_message({:invalid_nixploy_config_json, _detail}),
    do: "Nix configuration evaluation returned malformed JSON."

  def error_message(:path_info_not_an_object),
    do: "Nix path verification returned an unexpected JSON value."

  def error_message(:nixploy_config_not_an_object),
    do: "The flake nixploy output must be a JSON object."

  def error_message(:path_info_missing),
    do: "Nix did not return information for the exact requested store path."

  def error_message(:nar_hash_missing), do: "Nix did not return a valid NAR hash."

  def error_message({:nar_hash_changed, _expected, _actual}),
    do: "The NAR hash changed since this source was inspected; inspect it again."

  def error_message(:config_schema_missing), do: "The flake nixploy output has no __schema."

  def error_message({:unsupported_config_schema, schema}),
    do: "Unsupported nixploy schema #{safe_inspect(schema)}; expected v0.2."

  def error_message(:flake_project_or_targets_missing),
    do: "The v0.2 flake output must declare a project and targets."

  def error_message(:flake_targets_missing), do: "The flake declares no deployment targets."

  def error_message({:invalid_project, _reason}),
    do: "The flake project must be a bounded string."

  def error_message({:invalid_target_name, name}),
    do: "Flake target #{safe_inspect(name)} has an invalid name."

  def error_message({:invalid_target, name, field}),
    do: "Flake target #{name} has an invalid or missing #{field}."

  def error_message({:ambiguous_flake_targets, names}) do
    shown = names |> Enum.take(10) |> Enum.join(", ")
    suffix = if length(names) > 10, do: ", …", else: ""
    "Select one target derived from this flake: #{shown}#{suffix}."
  end

  def error_message({:flake_target_missing, name}),
    do: "Target #{name} is not declared by this immutable flake."

  def error_message(reason),
    do: "Could not stage the immutable source: #{safe_inspect(reason)}"

  defp path_info(store_path, execute, opts) do
    command = %Command{
      executable: nix_executable(),
      args: ["path-info", "--json", "--json-format", "1", "--", store_path],
      timeout: @path_info_timeout,
      max_output_bytes: @max_json_bytes
    }

    with {:ok, output} <- run(command, execute, opts, :path_info),
         {:ok, nar_hash} <- parse_path_info(output, store_path) do
      {:ok, nar_hash}
    end
  end

  defp evaluate(store_path, execute, opts) do
    command = %Command{
      executable: nix_executable(),
      args: ["eval", "--json", "--no-write-lock-file", "#{store_path}#nixploy"],
      timeout: @eval_timeout,
      max_output_bytes: @max_json_bytes
    }

    with {:ok, output} <- run(command, execute, opts, :eval),
         {:ok, config} <- parse_config(output) do
      {:ok, config}
    end
  end

  defp run(command, execute, opts, boundary) do
    execution_opts = Keyword.take(opts, [:cancelled?])

    case execute.(command, execution_opts) do
      {:ok, %{exit_status: 0, output_truncated?: false, output_tail: output}} ->
        {:ok, output}

      {:ok, %{exit_status: 0, output_truncated?: true}} ->
        {:error, output_too_large(boundary)}

      {:ok, result} ->
        {:error, command_failed(boundary, result.exit_status, result.output_tail)}

      {:error, :timeout} ->
        {:error, command_timeout(boundary)}

      {:error, :cancelled} ->
        {:error, :cancelled}

      {:error, reason} ->
        {:error, command_execution_failed(boundary, reason)}
    end
  end

  defp decode_json(output, :path_info) do
    case Jason.decode(output) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :path_info_not_an_object}
      {:error, error} -> {:error, {:invalid_path_info_json, Exception.message(error)}}
    end
  end

  defp decode_json(output, :nixploy_config) do
    case Jason.decode(output) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :nixploy_config_not_an_object}
      {:error, error} -> {:error, {:invalid_nixploy_config_json, Exception.message(error)}}
    end
  end

  defp exact_path_info(decoded, store_path) do
    case decoded do
      %{^store_path => info} when is_map(info) -> {:ok, info}
      _other -> {:error, :path_info_missing}
    end
  end

  defp extract_nar_hash(%{"narHash" => nar_hash}) when is_binary(nar_hash) do
    if byte_size(nar_hash) <= 255 and Regex.match?(@nar_hash, nar_hash),
      do: {:ok, nar_hash},
      else: {:error, :nar_hash_missing}
  end

  defp extract_nar_hash(_info), do: {:error, :nar_hash_missing}

  defp normalize_targets(targets) do
    targets
    |> Enum.sort_by(fn {name, _target} -> to_string(name) end)
    |> Enum.reduce_while({:ok, %{}}, fn
      {name, target}, {:ok, normalized} when is_binary(name) and is_map(target) ->
        with {:ok, name} <- required_string(name, :target_name),
             {:ok, snapshot} <- normalize_target(name, target) do
          {:cont, {:ok, Map.put(normalized, name, snapshot)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {name, _target}, _acc ->
        {:halt, {:error, {:invalid_target_name, name}}}
    end)
  end

  defp normalize_target(name, target) do
    # TODO(tracer): Add policy-safe credential references in the next Slice 1.4
    # increment. This first increment persists only fixed pre-start argv and
    # continues to reject every target that declares secrets.
    web = target["web"]
    slots = is_map(web) && web["slots"]
    run = target["run"] || %{}
    secrets = target["secrets"] || %{}

    with {:ok, image} <- target_string(target, "image", name),
         true <- is_map(web),
         {:ok, domain} <- target_string(web, "domain", name),
         {:ok, health_path} <- target_string(web, "healthPath", name),
         true <- String.starts_with?(health_path, "/"),
         true <- is_map(slots),
         {:ok, blue} <- target_port(slots, "blue", name),
         {:ok, green} <- target_port(slots, "green", name),
         true <- blue != green,
         {:ok, normalized_run} <- normalize_run(run, name),
         true <- is_map(secrets) do
      {:ok,
       %{
         "name" => name,
         "image_output" => image,
         "domain" => domain,
         "health_path" => health_path,
         "slots" => %{"blue" => blue, "green" => green},
         "run" => normalized_run,
         "pre_start_declared" => normalized_run["pre_start"] != [],
         "secrets_declared" => map_size(secrets) > 0
       }}
    else
      false -> {:error, {:invalid_target, name, "web or runtime configuration"}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_run(run, target_name) when is_map(run) do
    with {:ok, command} <- optional_argv(run["command"], target_name),
         {:ok, pre_start} <- pre_start_argv(run["preStart"] || [], target_name),
         {:ok, environment} <- string_map(run["environment"] || %{}, target_name),
         {:ok, network} <- optional_string(run["network"], target_name, "run.network"),
         {:ok, ports} <- string_list(run["ports"] || [], target_name, "run.ports") do
      {:ok,
       %{
         "command" => command,
         "pre_start" => pre_start,
         "environment" => environment,
         "network" => network,
         "ports" => ports
       }}
    end
  end

  defp normalize_run(_run, target_name),
    do: {:error, {:invalid_target, target_name, "run"}}

  defp optional_argv(nil, _target_name), do: {:ok, nil}

  defp optional_argv(argv, target_name) do
    argv(argv, target_name, "run.command")
  end

  defp pre_start_argv(actions, target_name)
       when is_list(actions) and length(actions) <= @max_pre_start_actions do
    actions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, normalized} ->
      case argv(action, target_name, "run.preStart[#{index}]") do
        {:ok, action} -> {:cont, {:ok, [action | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pre_start_argv(_actions, target_name),
    do: {:error, {:invalid_target, target_name, "run.preStart"}}

  defp argv(values, target_name, field)
       when is_list(values) and values != [] and length(values) <= @max_argv_items do
    if Enum.all?(values, &valid_argv_item?/1),
      do: {:ok, values},
      else: {:error, {:invalid_target, target_name, field}}
  end

  defp argv(_values, target_name, field),
    do: {:error, {:invalid_target, target_name, field}}

  defp valid_argv_item?(value),
    do:
      is_binary(value) and value != "" and byte_size(value) <= @max_value_bytes and
        not String.contains?(value, <<0>>)

  defp string_list(values, target_name, field) when is_list(values) do
    if Enum.all?(values, &valid_argv_item?/1),
      do: {:ok, values},
      else: {:error, {:invalid_target, target_name, field}}
  end

  defp string_list(_values, target_name, field),
    do: {:error, {:invalid_target, target_name, field}}

  defp string_map(values, target_name) when is_map(values) do
    if Enum.all?(values, fn {key, value} ->
         is_binary(key) and key != "" and byte_size(key) <= 255 and is_binary(value) and
           byte_size(value) <= @max_value_bytes
       end),
       do: {:ok, values},
       else: {:error, {:invalid_target, target_name, "run.environment"}}
  end

  defp string_map(_values, target_name),
    do: {:error, {:invalid_target, target_name, "run.environment"}}

  defp optional_string(nil, _target_name, _field), do: {:ok, nil}

  defp optional_string(value, target_name, field) when is_binary(value) do
    if value != "" and byte_size(value) <= @max_value_bytes,
      do: {:ok, value},
      else: {:error, {:invalid_target, target_name, field}}
  end

  defp optional_string(_value, target_name, field),
    do: {:error, {:invalid_target, target_name, field}}

  defp target_string(map, key, target_name) do
    case required_string(map[key], key) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, {:invalid_target, target_name, key}}
    end
  end

  defp target_port(map, key, target_name) do
    case map[key] do
      value when is_integer(value) and value in 1..65_535 -> {:ok, value}
      _value -> {:error, {:invalid_target, target_name, "web.slots.#{key}"}}
    end
  end

  defp required_string(value, field) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and byte_size(trimmed) <= @max_value_bytes,
      do: {:ok, trimmed},
      else: {:error, {invalid_string_code(field), :invalid}}
  end

  defp required_string(_value, field), do: {:error, {invalid_string_code(field), :invalid}}

  defp invalid_string_code(:project), do: :invalid_project
  defp invalid_string_code(:target_name), do: :invalid_target_name
  defp invalid_string_code(field), do: field

  defp selected(project, targets, name) do
    case Map.fetch(targets, name) do
      {:ok, target} ->
        snapshot = %{
          "schema" => @schema,
          "project" => project,
          "target" => target
        }

        {:ok, target, snapshot}

      :error ->
        {:error, {:flake_target_missing, name}}
    end
  end

  defp normalize_target_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      name -> name
    end
  end

  defp normalize_target_name(_value), do: nil

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, nested} ->
        [Jason.encode_to_iodata!(key), ?:, canonical_json(nested)]
      end)
      |> Enum.intersperse(?,)

    [?{, entries, ?}]
  end

  defp canonical_json(value) when is_list(value) do
    encoded = value |> Enum.map(&canonical_json/1) |> Enum.intersperse(?,)
    [?[, encoded, ?]]
  end

  defp canonical_json(value), do: Jason.encode_to_iodata!(value)

  defp output_too_large(:path_info), do: :path_info_output_too_large
  defp output_too_large(:eval), do: :eval_output_too_large
  defp command_timeout(:path_info), do: :path_info_timeout
  defp command_timeout(:eval), do: :eval_timeout
  defp command_failed(:path_info, status, output), do: {:path_info_failed, status, output}
  defp command_failed(:eval, status, output), do: {:eval_failed, status, output}

  defp command_execution_failed(:path_info, reason),
    do: {:path_info_command_failed, reason}

  defp command_execution_failed(:eval, reason), do: {:eval_command_failed, reason}

  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp failure_code({code, _one, _two}) when is_atom(code), do: Atom.to_string(code)
  defp failure_code(_reason), do: "staging_failed"

  defp safe_tail(output) when is_binary(output) do
    output
    |> String.replace_invalid("�")
    |> String.trim()
    |> String.slice(-1_000, 1_000)
    |> case do
      "" -> "no diagnostic output"
      tail -> tail
    end
  end

  defp safe_tail(_output), do: "no diagnostic output"

  defp command_error({:executable_not_found, executable}),
    do: "#{executable} is not available to the nixploy service"

  defp command_error(:cancelled), do: "operation was cancelled"
  defp command_error(reason), do: safe_inspect(reason)

  defp safe_inspect(value), do: value |> inspect(limit: 20, printable_limit: 500) |> safe_tail()

  defp nix_executable, do: Application.get_env(:nixploy, :nix_executable, "nix")
end
