defmodule Nixploy.Deployments.MainSource do
  @moduledoc "Exact main-only Git checkout and immutable Nix source materialization."

  alias Nixploy.Deployments.LocalStoreInput
  alias Nixploy.Execution
  alias Nixploy.Execution.Command
  alias Nixploy.ManagedApplications.Application, as: ManagedApplication

  @source_ref "refs/heads/main"
  @git_timeout :timer.minutes(2)
  @nix_timeout :timer.minutes(10)
  @metadata_bytes 8_192
  @command_bytes 65_536
  @oid ~r/^[0-9a-f]{40}$/

  def resolve_main(%ManagedApplication{} = application, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)

    command = %Command{
      executable: git_executable(),
      args: ["ls-remote", "--exit-code", "--refs", application.repository, @source_ref],
      env: git_env(application),
      timeout: @git_timeout,
      max_output_bytes: @metadata_bytes,
      redact: credential_redactions(application)
    }

    with {:ok, output} <- run(command, execute, opts, :git_resolve),
         {:ok, oid} <- parse_resolution(output) do
      {:ok, oid}
    end
  end

  def materialize(input, %ManagedApplication{} = application, opts \\ []) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    workspace_root = Keyword.get(opts, :workspace_root, workspace_root())
    workspace = Path.join(workspace_root, input.id)
    source = Path.join(workspace, "source")

    case private_workspace(workspace) do
      :ok ->
        try do
          checkout_and_materialize(input, application, source, execute, opts)
        after
          File.rm_rf(workspace)
        end

      {:error, _reason} = error ->
        error
    end
  end

  def parse_resolution(output) when is_binary(output) do
    rows =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, ~r/\s+/, parts: 2))

    case rows do
      [[oid, @source_ref]] ->
        if byte_size(oid) == 40 and Regex.match?(@oid, oid),
          do: {:ok, oid},
          else: {:error, :main_resolution_malformed}

      [] ->
        {:error, :main_not_found}

      _ ->
        {:error, :main_resolution_ambiguous}
    end
  end

  def failure(reason) do
    %{"code" => failure_code(reason), "message" => error_message(reason)}
  end

  def error_message(:main_not_found),
    do: "The trusted repository does not advertise refs/heads/main."

  def error_message(:main_resolution_malformed),
    do: "The main ref did not resolve to one full Git object ID."

  def error_message(:main_resolution_ambiguous),
    do: "The main ref returned ambiguous Git results."

  def error_message(:head_mismatch),
    do: "The exact checkout did not match the persisted main commit."

  def error_message(:source_dirty),
    do: "The exact checkout contains modified or untracked source."

  def error_message(:submodules_not_supported),
    do: "V1 rejects repositories containing submodules or gitlinks."

  def error_message(:flake_missing),
    do: "The configured source directory has no committed flake.nix."

  def error_message(:flake_lock_missing),
    do: "The configured source directory has no committed flake.lock."

  def error_message(:flake_lock_changed),
    do: "flake.lock changed while the source was being materialized."

  def error_message(:store_path_invalid),
    do: "Nix did not return one immutable source store path."

  def error_message(:commit_metadata_invalid), do: "Git returned invalid bounded commit metadata."

  def error_message(:workspace_unavailable),
    do: "The worker could not create a private preparation workspace."

  def error_message({:project_mismatch, expected, _actual}),
    do: "The flake project does not match managed application #{expected}."

  def error_message({:command_failed, boundary, status, output}),
    do: "#{boundary} exited with status #{status}: #{safe_tail(output)}"

  def error_message({:command_error, boundary, :timeout}), do: "#{boundary} timed out."
  def error_message({:command_error, _boundary, :cancelled}), do: "Preparation was cancelled."
  def error_message({:command_error, boundary, _reason}), do: "#{boundary} could not run."
  def error_message(reason), do: LocalStoreInput.error_message(reason)

  defp checkout_and_materialize(input, application, source, execute, opts) do
    env = git_env(application)

    with :ok <- command_ok(git(["init", "--quiet", source], env), execute, opts, :git_init),
         :ok <-
           command_ok(
             git(["-C", source, "remote", "add", "origin", application.repository], env),
             execute,
             opts,
             :git_remote
           ),
         :ok <-
           command_ok(
             git(
               [
                 "-C",
                 source,
                 "fetch",
                 "--quiet",
                 "--no-tags",
                 "--depth=1",
                 "origin",
                 input.source_revision
               ],
               env
             ),
             execute,
             opts,
             :git_fetch
           ),
         :ok <-
           command_ok(
             git(
               [
                 "-C",
                 source,
                 "checkout",
                 "--quiet",
                 "--detach",
                 "--force",
                 input.source_revision
               ],
               env
             ),
             execute,
             opts,
             :git_checkout
           ),
         {:ok, head} <-
           command_output(git(["-C", source, "rev-parse", "HEAD"], env), execute, opts, :git_head),
         :ok <- exact_head(head, input.source_revision),
         {:ok, status} <-
           command_output(
             git(["-C", source, "status", "--porcelain=v1", "--untracked-files=all"], env),
             execute,
             opts,
             :git_status
           ),
         :ok <- clean(status),
         :ok <- reject_submodules(source, env, execute, opts),
         {:ok, subject, timestamp} <-
           commit_metadata(source, input.source_revision, env, execute, opts),
         :ok <- strip_git_metadata(source),
         {:ok, flake_root, lock_hash} <- verify_flake_root(source, application.subdirectory),
         {:ok, store_path} <- store_add(flake_root, input, execute, opts),
         :ok <- unchanged_lock(flake_root, lock_hash),
         {:ok, probed} <- LocalStoreInput.probe(store_path, Keyword.put(opts, :execute, execute)),
         :ok <- exact_project(probed.project, application.project),
         {:ok, _target, snapshot} <- LocalStoreInput.select_target(probed, application.target),
         :ok <- retain(input.id, store_path, execute, opts) do
      {:ok,
       %{
         store_path: store_path,
         nar_hash: probed.nar_hash,
         commit_subject: subject,
         commit_timestamp: timestamp,
         derived_snapshot: snapshot,
         configuration_digest: LocalStoreInput.digest(snapshot)
       }}
    end
  end

  defp git(args, env) do
    %Command{
      executable: git_executable(),
      args: args,
      env: env,
      timeout: @git_timeout,
      max_output_bytes: @command_bytes,
      redact: []
    }
  end

  defp reject_submodules(source, env, execute, opts) do
    cond do
      File.exists?(Path.join(source, ".gitmodules")) ->
        {:error, :submodules_not_supported}

      true ->
        command = git(["-C", source, "ls-files", "--stage"], env)

        with {:ok, output} <- command_output(command, execute, opts, :git_index) do
          if output |> String.split("\n") |> Enum.any?(&String.starts_with?(&1, "160000 ")),
            do: {:error, :submodules_not_supported},
            else: :ok
        end
    end
  end

  defp commit_metadata(source, oid, env, execute, opts) do
    command = git(["-C", source, "show", "-s", "--format=%s%x00%cI", oid], env)

    with {:ok, output} <- command_output(command, execute, opts, :git_metadata),
         [subject, timestamp] <- String.trim_trailing(output) |> String.split(<<0>>, parts: 2),
         true <- byte_size(subject) <= 500,
         {:ok, parsed, _utc_offset} <- DateTime.from_iso8601(timestamp) do
      {:ok, subject, parsed}
    else
      _ -> {:error, :commit_metadata_invalid}
    end
  end

  defp strip_git_metadata(source) do
    case File.rm_rf(Path.join(source, ".git")) do
      {:ok, _entries} -> :ok
      {:error, _path, _reason} -> {:error, :workspace_unavailable}
    end
  end

  defp verify_flake_root(source, subdirectory) do
    root = Path.expand(subdirectory, source)

    if String.starts_with?(root, source <> "/") or root == source do
      flake = Path.join(root, "flake.nix")
      lock = Path.join(root, "flake.lock")

      cond do
        not File.regular?(flake) -> {:error, :flake_missing}
        not File.regular?(lock) -> {:error, :flake_lock_missing}
        true -> {:ok, root, file_hash(lock)}
      end
    else
      {:error, :flake_missing}
    end
  end

  defp store_add(root, input, execute, opts) do
    name = "nixploy-#{input.application_key}-#{String.slice(input.source_revision, 0, 12)}"

    command = %Command{
      executable: nix_executable(),
      args: ["store", "add", "--name", name, "--", root],
      timeout: @nix_timeout,
      max_output_bytes: @metadata_bytes
    }

    with {:ok, output} <- command_output(command, execute, opts, :nix_store_add) do
      path = String.trim(output)

      if Path.dirname(path) == "/nix/store" and String.split(output, "\n", trim: true) == [path],
        do: {:ok, path},
        else: {:error, :store_path_invalid}
    end
  end

  defp retain(id, store_path, execute, opts) do
    retain = Keyword.get(opts, :retain, &Nixploy.Deployments.ReleaseRoots.retain/4)
    retain.(id, store_path, execute, opts)
  end

  defp command_ok(command, execute, opts, boundary) do
    with {:ok, _output} <- command_output(command, execute, opts, boundary), do: :ok
  end

  defp command_output(command, execute, opts, boundary) do
    execution_opts = Keyword.take(opts, [:cancelled?])

    case execute.(command, execution_opts) do
      {:ok, %{exit_status: 0, output_truncated?: false, output_tail: output}} ->
        {:ok, output}

      {:ok, %{exit_status: status, output_tail: output}} ->
        {:error, {:command_failed, boundary, status, output}}

      {:error, reason} ->
        {:error, {:command_error, boundary, reason}}
    end
  end

  defp run(command, execute, opts, boundary), do: command_output(command, execute, opts, boundary)

  defp private_workspace(workspace) do
    case File.mkdir_p(workspace) do
      :ok ->
        case File.chmod(workspace, 0o700) do
          :ok -> :ok
          {:error, _reason} -> {:error, :workspace_unavailable}
        end

      {:error, _reason} ->
        {:error, :workspace_unavailable}
    end
  end

  defp exact_head(output, expected) do
    if String.trim(output) == expected, do: :ok, else: {:error, :head_mismatch}
  end

  defp clean(output), do: if(String.trim(output) == "", do: :ok, else: {:error, :source_dirty})
  defp exact_project(project, project), do: :ok
  defp exact_project(actual, expected), do: {:error, {:project_mismatch, expected, actual}}

  defp unchanged_lock(root, expected),
    do:
      if(file_hash(Path.join(root, "flake.lock")) == expected,
        do: :ok,
        else: {:error, :flake_lock_changed}
      )

  defp file_hash(path), do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1))

  defp git_env(application) do
    %{
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null"
    }
    |> maybe_ssh(application.credential_path)
  end

  defp maybe_ssh(env, nil), do: env

  defp maybe_ssh(env, path),
    do:
      Map.put(
        env,
        "GIT_SSH_COMMAND",
        "ssh -i #{path} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
      )

  defp credential_redactions(%{credential_path: nil}), do: []
  defp credential_redactions(%{credential_path: path}), do: [path]

  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code({:command_failed, boundary, _status, _output}), do: "#{boundary}_failed"
  defp failure_code({:command_error, boundary, reason}), do: "#{boundary}_#{reason}"
  defp failure_code({code, _a, _b}) when is_atom(code), do: Atom.to_string(code)
  defp failure_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp failure_code(_reason), do: "main_preparation_failed"

  defp safe_tail(output) do
    output
    |> to_string()
    |> String.replace_invalid("�")
    |> String.trim()
    |> String.slice(-1_000, 1_000)
  end

  defp workspace_root,
    do:
      Application.get_env(:nixploy, :preparation_workspace_root, "/var/lib/nixploy/preparations")

  defp git_executable, do: Application.get_env(:nixploy, :git_executable, "git")
  defp nix_executable, do: Application.get_env(:nixploy, :nix_executable, "nix")
end
