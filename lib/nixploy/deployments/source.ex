defmodule Nixploy.Deployments.Source do
  @moduledoc "Checks out a deployment's requested Git revision into an isolated workspace."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @clone_timeout :timer.minutes(10)

  def prepare(deployment, opts \\ []) do
    workspace = workspace(deployment.id)
    redactions = repository_redactions(deployment.service.repository.url)

    with :ok <- reset_workspace(workspace),
         {:ok, _result} <-
           git(
             [
               "clone",
               "--quiet",
               "--no-checkout",
               "--",
               deployment.service.repository.url,
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
               deployment.requested_ref
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
           git(["-C", workspace, "rev-parse", "HEAD"], opts, redactions) do
      {:ok, workspace, String.trim(result.output_tail)}
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
