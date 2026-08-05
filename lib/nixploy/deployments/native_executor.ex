defmodule Nixploy.Deployments.NativeExecutor do
  @moduledoc "Executes one verified local-store input against local Podman and Caddy."

  alias Nixploy.Deployments.{LocalStoreInput, NativeDeployment, ProjectCredentials}
  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @json_limit 1_048_576
  @diagnostic_limit 65_536
  @short_timeout :timer.seconds(30)
  @build_timeout :timer.minutes(15)
  @pre_start_timeout :timer.minutes(15)
  @health_attempts 20

  @spec deploy(NativeDeployment.t(), keyword()) :: :ok | {:error, term()}
  def deploy(%NativeDeployment{} = operation, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    stage = Keyword.fetch!(opts, :stage)
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)
    input = operation.deployment_input
    snapshot = input.derived_snapshot
    target = snapshot["target"]

    with :ok <- checkpoint(cancelled?),
         :ok <- stage.(:preparing, "Re-verifying immutable source and local runtime", %{}),
         {:ok, source} <- probe_source(input, opts, cancelled?),
         {:ok, plan} <- prepare_plan(operation, source, target, execute, cancelled?),
         :ok <- verify_operation_plan(operation, plan),
         :ok <- verify_previous_health(plan, target["health_path"], execute, cancelled?),
         :ok <- checkpoint(cancelled?),
         :ok <-
           stage.(:building, "Building the persisted flake image output", plan_attrs(plan)),
         {:ok, image_store_path} <-
           build(input.store_path, target["image_output"], execute, cancelled?),
         :ok <- checkpoint(cancelled?),
         :ok <-
           stage.(:loading, "Loading the built image into local rootless Podman", %{
             image_store_path: image_store_path
           }),
         {:ok, image_reference} <- load_image(image_store_path, execute, cancelled?),
         {:ok, image_id} <- inspect_image(image_reference, execute, cancelled?),
         :ok <- verify_expected_image(operation, image_id),
         :ok <- checkpoint(cancelled?),
         {:ok, secret_mounts} <-
           prepare_credentials(operation, plan, target, input, execute, cancelled?, stage, opts),
         :ok <- checkpoint(cancelled?),
         :ok <-
           stage.(:preparing_slot, "Validating and preparing only the inactive managed slot", %{
             image_store_path: image_store_path,
             image_reference: image_reference,
             image_id: image_id
           }),
         :ok <- prepare_inactive_slot(plan, execute, cancelled?),
         :ok <- checkpoint(cancelled?),
         :ok <-
           run_pre_start(
             plan,
             target,
             input,
             image_reference,
             secret_mounts,
             execute,
             cancelled?,
             stage
           ),
         :ok <- checkpoint(cancelled?),
         :ok <-
           stage.(:starting, "Starting the inactive slot from the verified image", %{
             container_name: plan.container_name
           }),
         {:ok, container_id} <-
           start_candidate(
             plan,
             target,
             input,
             image_reference,
             secret_mounts,
             execute,
             cancelled?
           ),
         :ok <- verify_candidate(plan, input, image_id, execute, cancelled?),
         :ok <- checkpoint(cancelled?),
         :ok <-
           stage.(:health_checking, "Checking the exact flake-declared candidate health path", %{
             container_id: container_id
           }),
         :ok <- health(plan, target["health_path"], execute, cancelled?, opts),
         :ok <- checkpoint(cancelled?),
         :ok <-
           stage.(:switching, "Candidate is healthy; switching the identified Caddy route", %{}),
         :ok <-
           switch_and_verify(
             plan,
             target["domain"],
             target["health_path"],
             input,
             image_id,
             execute,
             cancelled?,
             stage
           ),
         :ok <- stop_previous(plan, execute, cancelled?),
         :ok <-
           stage.(:succeeded, "Native deployment succeeded after independent readback", %{
             verified_upstream: upstream(plan.inactive_port)
           }) do
      :ok
    end
  end

  @doc false
  def failure(reason) do
    %{"code" => failure_code(reason), "message" => error_message(reason)}
  end

  def error_message(:cancelled), do: "operation was cancelled"
  def error_message(:native_source_hash_changed), do: "the staged NAR hash no longer matches"

  def error_message(:native_configuration_digest_changed),
    do: "the derived configuration digest no longer matches the staged input"

  def error_message(:credential_references_missing),
    do: "the staged input declares secrets without immutable credential references"

  def error_message(:credential_worker_required),
    do: "project credentials may only be resolved by the dedicated worker process"

  def error_message(:credential_identity_unavailable),
    do: "the worker SOPS identity credential is unavailable"

  def error_message(:credential_identity_invalid),
    do: "the worker SSH identity could not be converted to an age identity"

  def error_message({:credential_decryption_failed, label}),
    do: "worker decryption failed for credential reference #{label}"

  def error_message({:duplicate_credential, name}),
    do: "credential name #{name} is declared more than once"

  def error_message({:credential_resolution_failed, reason}),
    do: "worker credential resolution failed: #{safe_inspect(reason)}"

  def error_message({:pre_start_failed, index, count, reason}),
    do:
      "flake-declared pre-start action #{index} of #{count} failed before candidate startup: #{safe_inspect(reason)}"

  def error_message(:managed_identity_ambiguous),
    do: "multiple managed resource identities match this project and target"

  def error_message({:unmanaged_name_collision, name}),
    do: "refusing to mutate unmanaged container #{name}"

  def error_message(:caddy_state_unavailable), do: "identified Caddy state is unavailable"

  def error_message(:caddy_route_domain_mismatch),
    do: "the identified Caddy route belongs to another domain"

  def error_message(:caddy_upstream_invalid),
    do: "the identified Caddy upstream is malformed or ambiguous"

  def error_message(:active_slot_unmanaged),
    do: "the routed active slot is not positively managed by nixploy"

  def error_message(:active_slot_unhealthy),
    do: "the currently routed slot is not healthy; refusing to replace its peer"

  def error_message(:rollback_target_not_inactive),
    do: "the exact rollback slot is not inactive in the observed Caddy state"

  def error_message(:rollback_image_mismatch),
    do: "the rebuilt rollback image does not match the persisted verified image ID"

  def error_message({:caddy_switch_failed_previous_preserved, reason, upstream}),
    do:
      "Caddy switch failed, but the previous upstream #{upstream} was independently preserved: #{safe_inspect(reason)}"

  def error_message(:caddy_preservation_failed),
    do: "Caddy switch failed and the previous upstream could not be restored and verified"

  def error_message(:candidate_not_running), do: "the candidate container is not running"

  def error_message(:candidate_identity_mismatch),
    do: "candidate labels or image identity do not match the operation"

  def error_message(:health_failed), do: "candidate did not pass its exact health check"

  def error_message(:caddy_readback_mismatch),
    do: "Caddy did not retain the expected candidate upstream"

  def error_message(:nix_build_output_invalid),
    do: "Nix did not return one usable image output path"

  def error_message(:podman_load_output_invalid),
    do: "Podman did not report the loaded image reference"

  def error_message(reason), do: "native execution failed: #{safe_inspect(reason)}"

  defp probe_source(input, opts, cancelled?) do
    probe_opts =
      opts
      |> Keyword.take([:execute, :path_exists?])
      |> Keyword.put(:cancelled?, cancelled?)

    with {:ok, source} <- LocalStoreInput.probe(input.store_path, probe_opts),
         :ok <- verify_equal(source.nar_hash, input.nar_hash, :native_source_hash_changed),
         {:ok, _target, snapshot} <- LocalStoreInput.select_target(source, input.selected_target),
         :ok <-
           verify_equal(
             LocalStoreInput.digest(snapshot),
             input.configuration_digest,
             :native_configuration_digest_changed
           ) do
      references = snapshot["target"]["credential_references"] || %{}

      cond do
        not is_map(references) ->
          {:error, :credential_references_missing}

        snapshot["target"]["secrets_declared"] and map_size(references) == 0 ->
          {:error, :credential_references_missing}

        true ->
          {:ok, source}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_operation_plan(%NativeDeployment{operation_kind: :deploy}, _plan), do: :ok

  defp verify_operation_plan(%NativeDeployment{operation_kind: :rollback} = operation, plan) do
    if operation.expected_slot == plan.inactive_slot and is_binary(plan.previous_upstream),
      do: :ok,
      else: {:error, :rollback_target_not_inactive}
  end

  defp verify_expected_image(%NativeDeployment{operation_kind: :deploy}, _image_id), do: :ok

  defp verify_expected_image(%NativeDeployment{operation_kind: :rollback} = operation, image_id) do
    if image_matches?(image_id, operation.expected_image_id),
      do: :ok,
      else: {:error, :rollback_image_mismatch}
  end

  defp verify_previous_health(%{active_port: nil}, _path, _execute, _cancelled?), do: :ok

  defp verify_previous_health(plan, path, execute, cancelled?) do
    case health_once(plan.active_port, path, execute, cancelled?) do
      :ok -> :ok
      {:error, :cancelled} = error -> error
      {:error, _reason} -> {:error, :active_slot_unhealthy}
    end
  end

  defp prepare_plan(operation, source, target, execute, cancelled?) do
    with {:ok, containers} <- inventory(execute, cancelled?),
         {:ok, prefix} <- resource_prefix(source.project, operation.target, containers),
         :ok <- validate_collisions(prefix, source.project, operation.target, containers),
         {:ok, route} <- caddy_route(prefix, target["domain"], execute, cancelled?),
         {:ok, active_port} <- active_port(route, execute, cancelled?, prefix),
         {:ok, active_slot, inactive_slot, inactive_port} <-
           select_slot(active_port, target["slots"]),
         :ok <- validate_active(prefix, source.project, operation.target, active_slot, containers) do
      {:ok,
       %{
         project: source.project,
         target: operation.target,
         prefix: prefix,
         route_exists?: route == :existing,
         active_slot: active_slot,
         active_port: active_port,
         inactive_slot: inactive_slot,
         inactive_port: inactive_port,
         container_name: "#{prefix}-#{inactive_slot}",
         previous_container_name: active_slot && "#{prefix}-#{active_slot}",
         previous_upstream: active_port && upstream(active_port)
       }}
    end
  end

  defp inventory(execute, cancelled?) do
    command = %Command{
      executable: podman(),
      args: ["ps", "-a", "--format", "json"],
      timeout: @short_timeout,
      max_output_bytes: @json_limit
    }

    with {:ok, output} <- run(command, execute, cancelled?, :podman_inventory),
         {:ok, containers} when is_list(containers) <- Jason.decode(output) do
      {:ok, containers}
    else
      {:ok, _value} ->
        {:error, :podman_inventory_invalid}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:podman_inventory_invalid, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resource_prefix(project, target, containers) do
    prefixes =
      containers
      |> Enum.filter(&managed_for?(&1, project, target))
      |> Enum.map(&container_name/1)
      |> Enum.map(&slot_prefix/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case prefixes do
      [] -> {:ok, derived_prefix(project, target)}
      [prefix] -> {:ok, prefix}
      _multiple -> {:error, :managed_identity_ambiguous}
    end
  end

  defp derived_prefix(project, target) do
    identity = :crypto.hash(:sha256, project <> <<0>> <> target) |> Base.encode16(case: :lower)
    "nixploy-#{sanitize(project)}-#{String.slice(identity, 0, 10)}-#{sanitize(target)}"
  end

  defp validate_collisions(prefix, project, target, containers) do
    names = [prefix, "#{prefix}-blue", "#{prefix}-green"]

    case Enum.find(containers, fn container ->
           container_name(container) in names and not managed_for?(container, project, target)
         end) do
      nil -> :ok
      container -> {:error, {:unmanaged_name_collision, container_name(container)}}
    end
  end

  defp caddy_route(prefix, domain, execute, cancelled?) do
    case caddy_get("/id/#{route_id(prefix)}", execute, cancelled?) do
      {:ok, 404, _body} ->
        {:ok, :missing}

      {:ok, 200, body} ->
        if route_domain?(body, domain),
          do: {:ok, :existing},
          else: {:error, :caddy_route_domain_mismatch}

      _error ->
        {:error, :caddy_state_unavailable}
    end
  end

  defp active_port(route, execute, cancelled?, prefix) do
    case route do
      :missing ->
        {:ok, nil}

      :existing ->
        parse_active_port(caddy_get("/id/#{proxy_id(prefix)}/upstreams", execute, cancelled?))
    end
  end

  defp parse_active_port({:ok, 200, body}) do
    with {:ok, [%{"dial" => dial}]} when is_binary(dial) <- Jason.decode(body),
         [port_text] <- Regex.run(~r/(\d+)$/, dial, capture: :all_but_first),
         {port, ""} <- Integer.parse(port_text) do
      {:ok, port}
    else
      _invalid -> {:error, :caddy_upstream_invalid}
    end
  end

  defp parse_active_port(_response), do: {:error, :caddy_state_unavailable}

  defp select_slot(nil, %{"blue" => blue, "green" => _green}), do: {:ok, nil, "blue", blue}
  defp select_slot(blue, %{"blue" => blue, "green" => green}), do: {:ok, "blue", "green", green}
  defp select_slot(green, %{"blue" => blue, "green" => green}), do: {:ok, "green", "blue", blue}
  defp select_slot(_port, _slots), do: {:error, :caddy_upstream_invalid}

  defp validate_active(_prefix, _project, _target, nil, _containers), do: :ok

  defp validate_active(prefix, project, target, slot, containers) do
    case Enum.find(containers, &(container_name(&1) == "#{prefix}-#{slot}")) do
      nil ->
        {:error, :active_slot_unmanaged}

      container ->
        if managed_for?(container, project, target) and
             String.downcase(to_string(container["State"])) == "running",
           do: :ok,
           else: {:error, :active_slot_unmanaged}
    end
  end

  defp build(store_path, image_output, execute, cancelled?) do
    command = %Command{
      executable: nix(),
      # Execution combines stdout and stderr, so --quiet is required to keep
      # successful machine-readable Nix JSON free from progress diagnostics.
      args: [
        "build",
        "--quiet",
        "--json",
        "--no-link",
        "--no-update-lock-file",
        "--no-write-lock-file",
        "#{store_path}##{image_output}"
      ],
      timeout: @build_timeout,
      max_output_bytes: @json_limit
    }

    with {:ok, output} <- run(command, execute, cancelled?, :nix_build),
         {:ok, [%{"outputs" => outputs}]} when is_map(outputs) <- Jason.decode(output),
         [store_path] when is_binary(store_path) <- Map.values(outputs) do
      {:ok, store_path}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :nix_build_output_invalid}
    end
  end

  defp load_image(image_store_path, execute, cancelled?) do
    command = %Command{
      executable: podman(),
      args: ["load", "--input", image_store_path],
      timeout: :timer.minutes(5),
      max_output_bytes: @diagnostic_limit
    }

    with {:ok, output} <- run(command, execute, cancelled?, :podman_load),
         reference when is_binary(reference) <- loaded_reference(output) do
      {:ok, reference}
    else
      nil -> {:error, :podman_load_output_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp loaded_reference(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^Loaded image(?:\(s\))?:\s+(.+)$/i, String.trim(line)) do
        [_, reference] -> String.trim(reference)
        _no_match -> nil
      end
    end)
  end

  defp inspect_image(reference, execute, cancelled?) do
    command = %Command{
      executable: podman(),
      args: ["image", "inspect", "--format", "json", "--", reference],
      timeout: @short_timeout,
      max_output_bytes: @json_limit
    }

    with {:ok, output} <- run(command, execute, cancelled?, :podman_image_inspect),
         {:ok, [%{"Id" => id}]} when is_binary(id) <- Jason.decode(output) do
      {:ok, id}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :podman_image_inspect_invalid}
    end
  end

  defp prepare_inactive_slot(plan, execute, cancelled?) do
    with {:ok, containers} <- inventory(execute, cancelled?),
         :ok <- validate_collisions(plan.prefix, plan.project, plan.target, containers) do
      case Enum.find(containers, &(container_name(&1) == plan.container_name)) do
        nil ->
          :ok

        container ->
          if managed_for?(container, plan.project, plan.target),
            do: remove_container(plan.container_name, execute, cancelled?),
            else: {:error, {:unmanaged_name_collision, plan.container_name}}
      end
    end
  end

  defp remove_container(name, execute, cancelled?) do
    command = %Command{
      executable: podman(),
      args: ["rm", "--force", "--", name],
      timeout: @short_timeout
    }

    run_ok(command, execute, cancelled?, :podman_remove)
  end

  defp prepare_credentials(operation, plan, target, input, execute, cancelled?, stage, opts) do
    references = target["credential_references"] || %{}

    if map_size(references) == 0 do
      {:ok, []}
    else
      resolver = Keyword.get(opts, :resolve_credentials, &ProjectCredentials.resolve/2)

      with :ok <-
             stage.(:installing_credentials, "Resolving worker-only project credentials", %{
               metadata: %{credential_file_count: map_size(references)}
             }),
           {:ok, secrets} <-
             resolver.(references, execute: execute, cancelled?: cancelled?),
           {:ok, mounts} <-
             install_credentials(operation, plan, input, secrets, execute, cancelled?) do
        {:ok, mounts}
      else
        {:error, reason} -> {:error, normalize_credential_error(reason)}
      end
    end
  end

  defp install_credentials(operation, plan, input, secrets, execute, cancelled?) do
    secrets
    |> Enum.reduce_while({:ok, []}, fn secret, {:ok, mounts} ->
      source = secret_name(plan.prefix, operation.id, secret.name)

      labels = %{
        "io.nixploy.managed" => "true",
        "io.nixploy.project" => plan.project,
        "io.nixploy.target" => plan.target,
        "io.nixploy.deployment_input" => input.id
      }

      args =
        labels
        |> Enum.sort()
        |> Enum.reduce(["secret", "create"], fn {name, value}, args ->
          args ++ ["--label", "#{name}=#{value}"]
        end)
        |> Kernel.++([source, "-"])

      command = %Command{
        executable: podman(),
        args: args,
        stdin: secret.value,
        redact: [secret.value],
        timeout: @short_timeout,
        max_output_bytes: @diagnostic_limit
      }

      case run_ok(command, execute, cancelled?, :podman_secret_create) do
        :ok ->
          mount = %{source: source, target: secret.name, value: secret.value}
          {:cont, {:ok, [mount | mounts]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, mounts} -> {:ok, Enum.reverse(mounts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_credential_error(reason)
       when reason in [
              :credential_worker_required,
              :credential_identity_unavailable,
              :credential_identity_invalid
            ],
       do: reason

  defp normalize_credential_error({:credential_decryption_failed, _label} = reason), do: reason
  defp normalize_credential_error({:duplicate_credential, _name} = reason), do: reason
  defp normalize_credential_error(reason), do: {:credential_resolution_failed, reason}

  defp run_pre_start(
         plan,
         target,
         input,
         image_reference,
         secret_mounts,
         execute,
         cancelled?,
         stage
       ) do
    run = target["run"] || %{}
    actions = run["pre_start"] || []

    if actions == [] do
      :ok
    else
      with :ok <-
             stage.(:pre_starting, "Running flake-declared pre-start actions", %{
               metadata: %{action_count: length(actions)}
             }) do
        actions
        |> Enum.with_index(1)
        |> Enum.reduce_while(:ok, fn {argv, index}, :ok ->
          args =
            ["run", "--rm"]
            |> add_secret_mounts(secret_mounts)
            |> add_network(run["network"])
            |> add_environment(run["environment"] || %{}, plan.inactive_port)
            |> add_labels(plan, input)
            |> Kernel.++([image_reference])
            |> Kernel.++(argv)

          command = %Command{
            executable: podman(),
            args: args,
            timeout: @pre_start_timeout,
            redact: secret_values(secret_mounts),
            max_output_bytes: @diagnostic_limit
          }

          case run_ok(command, execute, cancelled?, :pre_start_action) do
            :ok ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, {:pre_start_failed, index, length(actions), reason}}}
          end
        end)
      end
    end
  end

  defp start_candidate(
         plan,
         target,
         input,
         image_reference,
         secret_mounts,
         execute,
         cancelled?
       ) do
    run = target["run"] || %{}

    args =
      ["run", "--detach", "--name", plan.container_name]
      |> add_secret_mounts(secret_mounts)
      |> add_network(run["network"])
      |> add_environment(run["environment"] || %{}, plan.inactive_port)
      |> add_ports(run["ports"] || [], plan.inactive_port)
      |> add_labels(plan, input)
      |> Kernel.++([image_reference])
      |> add_command(run["command"])

    command = %Command{
      executable: podman(),
      args: args,
      timeout: :timer.minutes(2),
      redact: secret_values(secret_mounts),
      max_output_bytes: @diagnostic_limit
    }

    with {:ok, output} <- run(command, execute, cancelled?, :podman_run),
         container_id when container_id != "" <- String.trim(output) do
      {:ok, container_id}
    else
      "" -> {:error, :podman_container_id_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_candidate(plan, input, image_id, execute, cancelled?) do
    with {:ok, container} <- inspect_container(plan.container_name, execute, cancelled?) do
      labels = get_in(container, ["Config", "Labels"])

      cond do
        get_in(container, ["State", "Running"]) != true ->
          {:error, :candidate_not_running}

        not image_matches?(container["Image"], image_id) ->
          {:error, :candidate_identity_mismatch}

        not is_map(labels) ->
          {:error, :candidate_identity_mismatch}

        labels["io.nixploy.managed"] != "true" or
          labels["io.nixploy.project"] != plan.project or
          labels["io.nixploy.target"] != plan.target or
          labels["io.nixploy.slot"] != plan.inactive_slot or
            labels["io.nixploy.deployment_input"] != input.id ->
          {:error, :candidate_identity_mismatch}

        true ->
          :ok
      end
    end
  end

  defp inspect_container(name, execute, cancelled?) do
    command = %Command{
      executable: podman(),
      args: ["container", "inspect", "--format", "json", "--", name],
      timeout: @short_timeout,
      max_output_bytes: @json_limit
    }

    with {:ok, output} <- run(command, execute, cancelled?, :podman_container_inspect),
         {:ok, [container]} when is_map(container) <- Jason.decode(output) do
      {:ok, container}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :podman_container_inspect_invalid}
    end
  end

  defp health(plan, path, execute, cancelled?, opts) do
    attempts = Keyword.get(opts, :health_attempts, @health_attempts)
    delay = Keyword.get(opts, :health_delay_ms, 1_000)

    Enum.reduce_while(1..attempts, {:error, :health_failed}, fn attempt, _last ->
      case health_once(plan.inactive_port, path, execute, cancelled?) do
        :ok ->
          {:halt, :ok}

        {:error, :cancelled} = error ->
          {:halt, error}

        {:error, _reason} when attempt < attempts ->
          if delay > 0, do: Process.sleep(delay)
          {:cont, {:error, :health_failed}}

        {:error, _reason} ->
          {:halt, {:error, :health_failed}}
      end
    end)
  end

  defp health_once(port, path, execute, cancelled?) do
    command = %Command{
      executable: curl(),
      args: [
        "--fail",
        "--silent",
        "--show-error",
        "--output",
        "/dev/null",
        "--max-time",
        "2",
        "--",
        "http://127.0.0.1:#{port}#{path}"
      ],
      timeout: :timer.seconds(4),
      max_output_bytes: 4_096
    }

    run_ok(command, execute, cancelled?, :candidate_health)
  end

  defp switch_and_verify(
         plan,
         domain,
         health_path,
         input,
         image_id,
         execute,
         cancelled?,
         stage
       ) do
    case switch_caddy(plan, domain, execute, cancelled?) do
      :ok ->
        result =
          with :ok <- checkpoint(cancelled?),
               :ok <-
                 stage.(
                   :verifying,
                   "Reading back Caddy, container identity, and exact health",
                   %{}
                 ),
               :ok <-
                 verify_switch(plan, health_path, input, image_id, execute, cancelled?) do
            :ok
          end

        case result do
          :ok ->
            :ok

          # Once ingress mutation was attempted, cancellation cannot interrupt
          # the bounded preservation readback/compensation sequence.
          {:error, reason} ->
            preserve_after_applied_switch(plan, reason, execute, fn -> false end)
        end

      {:error, reason} ->
        preserve_after_uncertain_switch(plan, reason, execute, fn -> false end)
    end
  end

  defp preserve_after_applied_switch(
         %{previous_upstream: nil} = plan,
         reason,
         execute,
         cancelled?
       ) do
    remove_new_route(plan, reason, execute, cancelled?)
  end

  defp preserve_after_applied_switch(plan, reason, execute, cancelled?) do
    restore_previous_upstream(plan, reason, execute, cancelled?)
  end

  defp preserve_after_uncertain_switch(
         %{previous_upstream: nil} = plan,
         reason,
         execute,
         cancelled?
       ) do
    case caddy_get("/id/#{route_id(plan.prefix)}", execute, cancelled?) do
      {:ok, 404, _body} -> {:error, reason}
      {:ok, 200, _body} -> remove_new_route(plan, reason, execute, cancelled?)
      _other -> {:error, :caddy_preservation_failed}
    end
  end

  defp preserve_after_uncertain_switch(plan, reason, execute, cancelled?) do
    case active_port(:existing, execute, cancelled?, plan.prefix) do
      {:ok, port} when port == plan.active_port ->
        preserved_switch_error(plan, reason)

      {:ok, port} when port == plan.inactive_port ->
        restore_previous_upstream(plan, reason, execute, cancelled?)

      _other ->
        {:error, :caddy_preservation_failed}
    end
  end

  defp restore_previous_upstream(plan, original_reason, execute, cancelled?) do
    body = Jason.encode!([%{"dial" => plan.previous_upstream}])

    with :ok <-
           caddy_mutate(
             "PATCH",
             "/id/#{proxy_id(plan.prefix)}/upstreams",
             body,
             execute,
             cancelled?
           ),
         {:ok, restored_port} <- active_port(:existing, execute, cancelled?, plan.prefix),
         true <- restored_port == plan.active_port do
      preserved_switch_error(plan, original_reason)
    else
      _failure -> {:error, :caddy_preservation_failed}
    end
  end

  defp preserved_switch_error(plan, reason),
    do: {:error, {:caddy_switch_failed_previous_preserved, reason, plan.previous_upstream}}

  defp remove_new_route(plan, original_reason, execute, cancelled?) do
    with :ok <- caddy_delete("/id/#{route_id(plan.prefix)}", execute, cancelled?),
         {:ok, 404, _body} <- caddy_get("/id/#{route_id(plan.prefix)}", execute, cancelled?) do
      {:error, original_reason}
    else
      _failure -> {:error, :caddy_preservation_failed}
    end
  end

  defp switch_caddy(%{route_exists?: false} = plan, domain, execute, cancelled?) do
    body = route_json(plan, domain)
    caddy_mutate("POST", "/config/apps/http/servers/nixploy/routes", body, execute, cancelled?)
  end

  defp switch_caddy(plan, _domain, execute, cancelled?) do
    body = Jason.encode!([%{"dial" => upstream(plan.inactive_port)}])
    caddy_mutate("PATCH", "/id/#{proxy_id(plan.prefix)}/upstreams", body, execute, cancelled?)
  end

  defp verify_switch(plan, health_path, input, image_id, execute, cancelled?) do
    with {:ok, port} <- active_port(:existing, execute, cancelled?, plan.prefix),
         true <- port == plan.inactive_port,
         :ok <- verify_candidate(plan, input, image_id, execute, cancelled?),
         :ok <- health_once(plan.inactive_port, health_path, execute, cancelled?) do
      :ok
    else
      false -> {:error, :caddy_readback_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_previous(%{previous_container_name: nil}, _execute, _cancelled?), do: :ok

  defp stop_previous(plan, execute, cancelled?) do
    command = %Command{
      executable: podman(),
      args: ["stop", "--time", "10", "--", plan.previous_container_name],
      timeout: @short_timeout
    }

    run_ok(command, execute, cancelled?, :podman_stop_previous)
  end

  defp caddy_get(path, execute, cancelled?) do
    command = %Command{
      executable: curl(),
      args: [
        "--silent",
        "--show-error",
        "--output",
        "-",
        "--write-out",
        "\n%{http_code}",
        "--",
        caddy_url(path)
      ],
      timeout: @short_timeout,
      max_output_bytes: @json_limit
    }

    with {:ok, output} <- run(command, execute, cancelled?, :caddy_get),
         {body, status} <- split_http_response(output) do
      {:ok, status, body}
    else
      nil -> {:error, :caddy_response_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp caddy_mutate(method, path, body, execute, cancelled?) do
    command = %Command{
      executable: curl(),
      args: [
        "--fail-with-body",
        "--silent",
        "--show-error",
        "--request",
        method,
        "--header",
        "Content-Type: application/json",
        "--data-binary",
        body,
        "--",
        caddy_url(path)
      ],
      timeout: @short_timeout,
      max_output_bytes: @diagnostic_limit
    }

    run_ok(command, execute, cancelled?, :caddy_mutation)
  end

  defp caddy_delete(path, execute, cancelled?) do
    command = %Command{
      executable: curl(),
      args: [
        "--fail-with-body",
        "--silent",
        "--show-error",
        "--request",
        "DELETE",
        "--",
        caddy_url(path)
      ],
      timeout: @short_timeout,
      max_output_bytes: @diagnostic_limit
    }

    run_ok(command, execute, cancelled?, :caddy_mutation)
  end

  defp split_http_response(output) do
    output = String.trim_trailing(output)

    case :binary.matches(output, "\n") |> List.last() do
      {index, 1} ->
        body = binary_part(output, 0, index)
        status_text = binary_part(output, index + 1, byte_size(output) - index - 1)

        case Integer.parse(String.trim(status_text)) do
          {status, ""} -> {body, status}
          _invalid -> nil
        end

      nil ->
        nil
    end
  end

  defp route_domain?(body, domain) do
    with {:ok, route} when is_map(route) <- Jason.decode(body) do
      route
      |> Map.get("match", [])
      |> Enum.any?(fn matcher -> domain in Map.get(matcher, "host", []) end)
    else
      _invalid -> false
    end
  end

  defp route_json(plan, domain) do
    Jason.encode!(%{
      "@id" => route_id(plan.prefix),
      "match" => [%{"host" => [domain]}],
      "handle" => [
        %{
          "handler" => "subroute",
          "routes" => [
            %{
              "handle" => [
                %{
                  "@id" => proxy_id(plan.prefix),
                  "handler" => "reverse_proxy",
                  "upstreams" => [%{"dial" => upstream(plan.inactive_port)}]
                }
              ]
            }
          ]
        }
      ],
      "terminal" => true
    })
  end

  defp run_ok(command, execute, cancelled?, boundary) do
    case run(command, execute, cancelled?, boundary) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(command, execute, cancelled?, boundary) do
    case execute.(command, cancelled?: cancelled?) do
      {:ok, %{exit_status: 0, output_truncated?: false, output_tail: output}} ->
        {:ok, output}

      {:ok, %{exit_status: 0, output_truncated?: true}} ->
        {:error, {boundary, :output_too_large}}

      {:ok, result} ->
        {:error, {boundary, :command_failed, result.exit_status, safe_tail(result.output_tail)}}

      {:error, :cancelled} ->
        {:error, :cancelled}

      {:error, reason} ->
        {:error, {boundary, reason}}
    end
  end

  defp verify_equal(value, value, _error), do: :ok
  defp verify_equal(_actual, _expected, error), do: {:error, error}

  defp checkpoint(cancelled?) do
    if cancelled?.(), do: {:error, :cancelled}, else: :ok
  end

  defp plan_attrs(plan) do
    %{
      resource_prefix: plan.prefix,
      previous_upstream: plan.previous_upstream,
      selected_slot: plan.inactive_slot,
      selected_port: plan.inactive_port
    }
  end

  defp managed_for?(container, project, target) do
    labels = container["Labels"] || %{}
    managed = labels["io.nixploy.managed"] == "true" or is_binary(labels["nixploy.project"])

    managed and (labels["io.nixploy.project"] || labels["nixploy.project"]) == project and
      (labels["io.nixploy.target"] || labels["nixploy.target"]) == target
  end

  defp container_name(container) do
    case container["Names"] || container["Name"] do
      [name | _] -> String.trim_leading(name, "/")
      name when is_binary(name) -> String.trim_leading(name, "/")
      _other -> ""
    end
  end

  defp slot_prefix(name) do
    cond do
      String.ends_with?(name, "-blue") -> String.trim_trailing(name, "-blue")
      String.ends_with?(name, "-green") -> String.trim_trailing(name, "-green")
      true -> nil
    end
  end

  defp sanitize(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 48)
  end

  defp add_secret_mounts(args, mounts) do
    Enum.reduce(mounts, args, fn mount, acc ->
      acc ++ ["--secret", "source=#{mount.source},type=env,target=#{mount.target}"]
    end)
  end

  defp secret_values(mounts), do: Enum.map(mounts, & &1.value)

  defp secret_name(prefix, operation_id, target) do
    operation = operation_id |> String.replace("-", "") |> String.slice(0, 12)

    target_hash =
      :crypto.hash(:sha256, target) |> Base.encode16(case: :lower) |> String.slice(0, 12)

    "#{prefix}-secret-#{operation}-#{target_hash}"
  end

  defp add_network(args, nil), do: args
  defp add_network(args, network), do: args ++ ["--network", network]

  defp add_environment(args, environment, port) do
    Enum.reduce(Enum.sort(environment), args, fn {name, value}, acc ->
      acc ++ ["--env", "#{name}=#{render(value, port)}"]
    end)
  end

  defp add_ports(args, ports, port) do
    Enum.reduce(ports, args, fn mapping, acc -> acc ++ ["--publish", render(mapping, port)] end)
  end

  defp add_labels(args, plan, input) do
    labels = %{
      "io.nixploy.managed" => "true",
      "io.nixploy.project" => plan.project,
      "io.nixploy.target" => plan.target,
      "io.nixploy.slot" => plan.inactive_slot,
      "io.nixploy.deployment_input" => input.id,
      "io.nixploy.store_path" => input.store_path,
      "io.nixploy.nar_hash" => input.nar_hash,
      "io.nixploy.configuration_digest" => input.configuration_digest,
      "nixploy.project" => plan.project,
      "nixploy.target" => plan.target
    }

    Enum.reduce(Enum.sort(labels), args, fn {name, value}, acc ->
      acc ++ ["--label", "#{name}=#{value}"]
    end)
  end

  defp add_command(args, nil), do: args
  defp add_command(args, command), do: args ++ command
  defp render(value, port), do: String.replace(value, "{port}", Integer.to_string(port))

  defp image_matches?(actual, expected),
    do:
      actual == expected or
        String.trim_leading(actual || "", "sha256:") ==
          String.trim_leading(expected || "", "sha256:")

  defp upstream(port), do: "127.0.0.1:#{port}"
  defp route_id(prefix), do: "nixploy-route-#{prefix}"
  defp proxy_id(prefix), do: "nixploy-proxy-#{prefix}"

  defp caddy_url(path),
    do: Application.get_env(:nixploy, :caddy_admin_url, "http://127.0.0.1:2019") <> path

  defp nix, do: Application.get_env(:nixploy, :nix_executable, "nix")
  defp podman, do: Application.get_env(:nixploy, :podman_executable, "podman")
  defp curl, do: Application.get_env(:nixploy, :curl_executable, "curl")

  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp failure_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      code when is_atom(code) -> Atom.to_string(code)
      _other -> "native_execution_failed"
    end
  end

  defp failure_code(_reason), do: "native_execution_failed"

  defp safe_tail(output),
    do: output |> String.replace_invalid("�") |> String.trim() |> String.slice(-1_000, 1_000)

  defp safe_inspect(reason), do: reason |> inspect(limit: 20, printable_limit: 500) |> safe_tail()
end
