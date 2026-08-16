defmodule Nixploy.Deployments.Source do
  @moduledoc "Checks out a deployment's requested Git revision into an isolated workspace."

  alias Nixploy.Deployments.Spec
  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @clone_timeout :timer.minutes(10)

  # TODO(tracer): Dispatch persisted local-store inputs to a store-path
  # verifier instead of teaching this Git adapter about non-Git sources.
  def prepare(deployment, opts \\ []) do
    workspace = workspace(deployment.id)
    repository_url = Spec.repository_url(deployment.service_snapshot)
    revision = deployment.resolved_commit || deployment.requested_ref
    redactions = repository_redactions(repository_url)

    with :ok <- reset_workspace(workspace),
         {:ok, _result} <-
           git(
             [
               "clone",
               "--quiet",
               "--no-checkout",
               "--",
               repository_url,
               workspace
             ],
             opts,
             redactions
           ),
         {:ok, _result} <-
           git(
             [
               "-C",
               workspace,
               "fetch",
               "--quiet",
               "--depth=1",
               "--no-tags",
               "--",
               "origin",
               revision
             ],
             opts,
             redactions
           ),
         {:ok, _result} <-
           git(
             ["-C", workspace, "checkout", "--quiet", "--detach", "FETCH_HEAD"],
             opts,
             redactions
           ),
         {:ok, result} <-
           git(["-C", workspace, "rev-parse", "HEAD"], opts, redactions),
         commit = String.trim(result.output_tail),
         :ok <- verify_pinned_commit(deployment.resolved_commit, commit),
         {:ok, working_directory} <- working_directory(deployment, workspace) do
      {:ok, working_directory, commit}
    end
  end

  def workspace(deployment_id) do
    root =
      Application.get_env(
        :nixploy,
        :deployment_workspace_root,
        Path.join(System.tmp_dir!(), "nixploy-deployments")
      )

    Path.join(root, deployment_id)
  end

  def cleanup(deployment_id), do: deployment_id |> workspace() |> File.rm_rf()

  defp reset_workspace(workspace) do
    with {:ok, _removed} <- File.rm_rf(workspace),
         :ok <- File.mkdir_p(Path.dirname(workspace)) do
      :ok
    end
  end

  defp git(args, opts, redactions) do
    command = %Command{
      executable: "git",
      args: args,
      timeout: @clone_timeout,
      redact: redactions
    }

    case Execution.run(command, opts) do
      {:ok, %{exit_status: 0} = result} -> {:ok, result}
      {:ok, result} -> {:error, {:git_failed, result.exit_status, result.output_tail}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp working_directory(deployment, workspace) do
    subdirectory = Spec.repository_subdirectory(deployment.service_snapshot)

    with {:ok, safe_path} <- Path.safe_relative(subdirectory, workspace),
         working_directory = Path.join(workspace, safe_path),
         true <- File.dir?(working_directory) do
      {:ok, working_directory}
    else
      :error -> {:error, {:invalid_repository_subdirectory, subdirectory}}
      false -> {:error, {:repository_subdirectory_not_found, subdirectory}}
    end
  end

  defp verify_pinned_commit(nil, _commit), do: :ok
  defp verify_pinned_commit(commit, commit), do: :ok

  defp verify_pinned_commit(expected, actual),
    do: {:error, {:resolved_commit_mismatch, expected, actual}}

  defp repository_redactions(url) do
    uri = URI.parse(url)

    [url, uri.userinfo]
    |> Enum.concat(userinfo_password(uri.userinfo))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp userinfo_password(nil), do: []

  defp userinfo_password(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [_user, password] -> [password]
      [_user] -> []
    end
  end
end
