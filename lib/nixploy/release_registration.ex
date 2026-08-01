defmodule Nixploy.ReleaseRegistration do
  @moduledoc "Authenticated, bounded CI delivery of immutable Nix release sources."

  alias Nixploy.Deployments
  alias Nixploy.Deployments.LocalStoreInput
  alias Nixploy.Execution
  alias Nixploy.Execution.Command
  alias Nixploy.{Accounts, Audit}

  @max_export_bytes 32 * 1_024 * 1_024
  @max_token_bytes 4_096
  @import_timeout :timer.minutes(5)
  @max_output_bytes 65_536
  @revision ~r/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/
  @repository ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/
  @nar_hash ~r/^sha256-[A-Za-z0-9+\/_=.~-]+$/

  def max_export_bytes, do: @max_export_bytes

  def authenticate(token) when is_binary(token) do
    with {:ok, config} <- config(),
         {:ok, expected} <- configured_token(config),
         true <- secure_match?(token, expected),
         operator when not is_nil(operator) <-
           Accounts.get_operator_by_email(Keyword.fetch!(config, :operator_email)) do
      {:ok, operator, config}
    else
      _error -> {:error, :unauthorized}
    end
  end

  def authenticate(_token), do: {:error, :unauthorized}

  def register(attrs, export, operator, config, opts \\ [])

  def register(attrs, export, operator, config, opts)
      when is_map(attrs) and is_binary(export) do
    execute =
      Keyword.get(
        opts,
        :execute,
        Application.get_env(:nixploy, :release_registration_execute, &Execution.run/2)
      )

    request_id = Keyword.get(opts, :request_id, "unknown")

    with {:ok, metadata} <- validate_metadata(attrs, config),
         :ok <- validate_export(export),
         {:ok, imported_path} <- import_export(export, execute),
         :ok <- verify_imported_path(metadata.store_path, imported_path),
         {:ok, input, disposition} <- stage_or_reuse(metadata, operator, opts) do
      :ok = record(operator, :ci_release_registered, input.id, :succeeded, metadata, request_id)
      {:ok, input, disposition}
    else
      {:error, reason} = error ->
        :ok = record_failure(operator, attrs, reason, request_id)
        error
    end
  end

  def register(_attrs, _export, operator, _config, opts) do
    request_id = Keyword.get(opts, :request_id, "unknown")
    :ok = record_failure(operator, %{}, :invalid_request, request_id)
    {:error, :invalid_request}
  end

  def error_message(:unauthorized), do: "release registration credentials were rejected"
  def error_message(:invalid_content_type), do: "use application/x-nix-export"
  def error_message(:export_required), do: "the Nix export body is empty"
  def error_message(:export_too_large), do: "the Nix export exceeds the 32 MiB limit"
  def error_message(:invalid_store_path), do: "x-nixploy-store-path is invalid"
  def error_message(:invalid_nar_hash), do: "x-nixploy-nar-hash is invalid"
  def error_message(:invalid_project), do: "x-nixploy-project is not authorized"
  def error_message(:invalid_target), do: "x-nixploy-target is not authorized"
  def error_message(:invalid_repository), do: "x-nixploy-repository is not authorized"
  def error_message(:invalid_revision), do: "x-nixploy-revision must be a full Git object ID"
  def error_message(:import_timeout), do: "Nix import timed out after 5 minutes"
  def error_message(:import_output_too_large), do: "Nix import diagnostics exceeded 64 KiB"
  def error_message({:import_failed, status}), do: "Nix import exited with status #{status}"
  def error_message({:import_command_failed, _reason}), do: "Nix import could not be executed"

  def error_message(:imported_path_mismatch),
    do: "the Nix export did not contain the declared path"

  def error_message(%{failure: %{"message" => message}}), do: message
  def error_message(_reason), do: "release registration failed"

  defp config do
    case Application.get_env(:nixploy, :release_registration) do
      config when is_list(config) and config != [] -> {:ok, config}
      _config -> {:error, :disabled}
    end
  end

  defp configured_token(config) do
    case Keyword.get(config, :token) do
      token when is_binary(token) -> validate_token(token)
      _token -> read_token_file(Keyword.get(config, :token_file))
    end
  end

  defp read_token_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, token} when byte_size(token) <= @max_token_bytes -> validate_token(token)
      _error -> {:error, :invalid_token_file}
    end
  end

  defp read_token_file(_path), do: {:error, :invalid_token_file}

  defp validate_token(token) do
    token = String.trim(token)
    if byte_size(token) >= 32, do: {:ok, token}, else: {:error, :invalid_token}
  end

  defp secure_match?(provided, expected) do
    provided_digest = :crypto.hash(:sha256, provided)
    expected_digest = :crypto.hash(:sha256, expected)
    Plug.Crypto.secure_compare(provided_digest, expected_digest)
  end

  defp validate_metadata(attrs, config) do
    metadata = %{
      store_path: value(attrs, :store_path),
      nar_hash: value(attrs, :nar_hash),
      project: value(attrs, :project),
      target: value(attrs, :target),
      repository: value(attrs, :repository),
      revision: value(attrs, :revision)
    }

    with {:ok, store_path} <-
           LocalStoreInput.validate_store_path(metadata.store_path, fn _path -> true end),
         true <- valid_nar_hash?(metadata.nar_hash),
         true <- metadata.project == Keyword.fetch!(config, :project),
         true <- metadata.target == Keyword.fetch!(config, :target),
         true <- metadata.repository == Keyword.fetch!(config, :repository),
         true <- is_binary(metadata.repository) and Regex.match?(@repository, metadata.repository),
         true <- is_binary(metadata.revision) and Regex.match?(@revision, metadata.revision) do
      {:ok, %{metadata | store_path: store_path}}
    else
      {:error, _reason} -> {:error, :invalid_store_path}
      false -> metadata_error(metadata, config)
    end
  end

  defp metadata_error(metadata, config) do
    cond do
      not valid_nar_hash?(metadata.nar_hash) ->
        {:error, :invalid_nar_hash}

      metadata.project != Keyword.fetch!(config, :project) ->
        {:error, :invalid_project}

      metadata.target != Keyword.fetch!(config, :target) ->
        {:error, :invalid_target}

      metadata.repository != Keyword.fetch!(config, :repository) ->
        {:error, :invalid_repository}

      not is_binary(metadata.repository) or not Regex.match?(@repository, metadata.repository) ->
        {:error, :invalid_repository}

      true ->
        {:error, :invalid_revision}
    end
  end

  defp validate_export(<<>>), do: {:error, :export_required}

  defp validate_export(export) when byte_size(export) <= @max_export_bytes, do: :ok
  defp validate_export(_export), do: {:error, :export_too_large}

  defp import_export(export, execute) do
    command = %Command{
      executable: "nix-store",
      args: ["--import"],
      stdin: export,
      timeout: @import_timeout,
      max_output_bytes: @max_output_bytes
    }

    case execute.(command, []) do
      {:ok, %{exit_status: 0, output_truncated?: false, output_tail: output}} ->
        imported_path(output)

      {:ok, %{exit_status: 0, output_truncated?: true}} ->
        {:error, :import_output_too_large}

      {:ok, %{exit_status: status}} ->
        {:error, {:import_failed, status}}

      {:error, :timeout} ->
        {:error, :import_timeout}

      {:error, reason} ->
        {:error, {:import_command_failed, reason}}
    end
  end

  defp imported_path(output) do
    paths =
      Regex.scan(~r|/nix/store/[0-9a-z]{32}-[^\s]+|, output) |> List.flatten() |> Enum.uniq()

    if length(paths) == 1, do: {:ok, hd(paths)}, else: {:error, :imported_path_mismatch}
  end

  defp verify_imported_path(path, path), do: :ok
  defp verify_imported_path(_expected, _actual), do: {:error, :imported_path_mismatch}

  defp stage_or_reuse(metadata, operator, opts) do
    case Deployments.get_staged_release(metadata.store_path, metadata.target) do
      nil ->
        stage(metadata, operator, opts)

      existing ->
        if existing.nar_hash == metadata.nar_hash and
             get_in(existing.derived_snapshot, ["project"]) == metadata.project do
          {:ok, existing, :existing}
        else
          {:error, :existing_release_identity_mismatch}
        end
    end
  end

  defp stage(metadata, operator, opts) do
    staging_opts =
      opts
      |> Keyword.take([:execute, :path_exists?])
      |> Keyword.put(:operator, operator)
      |> Keyword.put(:expected_project, metadata.project)

    case Deployments.stage_local_store(
           %{
             store_path: metadata.store_path,
             selected_target: metadata.target,
             expected_nar_hash: metadata.nar_hash,
             registration_channel: :ci,
             source_repository: metadata.repository,
             source_revision: metadata.revision
           },
           staging_opts
         ) do
      {:ok, input} -> {:ok, input, :created}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(operator, action, resource_id, outcome, metadata, request_id) do
    audit_metadata = %{
      "request_id" => request_id,
      "project" => metadata.project,
      "target" => metadata.target,
      "repository" => metadata.repository,
      "revision" => metadata.revision,
      "store_path" => metadata.store_path,
      "nar_hash" => metadata.nar_hash
    }

    case Audit.record(operator, action, :deployment_input, resource_id,
           outcome: outcome,
           metadata: audit_metadata
         ) do
      {:ok, _event} -> :ok
      {:error, reason} -> raise "could not persist CI release audit: #{inspect(reason)}"
    end
  end

  defp record_failure(operator, attrs, reason, request_id) do
    metadata = %{
      "request_id" => request_id,
      "project" => value(attrs, :project),
      "target" => value(attrs, :target),
      "repository" => value(attrs, :repository),
      "revision" => value(attrs, :revision),
      "store_path" => value(attrs, :store_path),
      "failure_code" => failure_code(reason)
    }

    case Audit.record(
           operator,
           :ci_release_registration_failed,
           :release_registration,
           request_id,
           outcome: :failed,
           metadata: metadata
         ) do
      {:ok, _event} ->
        :ok

      {:error, audit_reason} ->
        raise "could not persist CI release failure audit: #{inspect(audit_reason)}"
    end
  end

  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp failure_code(%{failure: %{"code" => code}}), do: code
  defp failure_code(_reason), do: "registration_failed"

  defp valid_nar_hash?(value),
    do: is_binary(value) and byte_size(value) <= 255 and Regex.match?(@nar_hash, value)

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
