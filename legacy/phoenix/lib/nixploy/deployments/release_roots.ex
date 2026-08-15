defmodule Nixploy.Deployments.ReleaseRoots do
  @moduledoc "Creates durable indirect GC roots for prepared release sources."

  alias Nixploy.Execution.Command

  @timeout :timer.seconds(30)

  def retain(id, store_path, execute, opts) do
    root_directory = Keyword.get(opts, :gc_root_directory, root_directory())
    root = Path.join(root_directory, id)

    with :ok <- File.mkdir_p(root_directory),
         :ok <- File.chmod(root_directory, 0o700),
         {:ok, %{exit_status: 0, output_truncated?: false}} <-
           execute.(
             %Command{
               executable: nix_store_executable(),
               args: ["--add-root", root, "--indirect", "--realise", store_path],
               timeout: @timeout,
               max_output_bytes: 8_192
             },
             Keyword.take(opts, [:cancelled?])
           ) do
      :ok
    else
      {:ok, %{exit_status: status, output_tail: output}} ->
        {:error, {:gc_root_failed, status, safe_tail(output)}}

      {:error, reason} ->
        {:error, {:gc_root_failed, reason}}
    end
  end

  def path(id), do: Path.join(root_directory(), id)

  defp root_directory,
    do:
      Application.get_env(
        :nixploy,
        :release_gc_root_directory,
        "/var/lib/nixploy/gcroots/releases"
      )

  defp nix_store_executable,
    do: Application.get_env(:nixploy, :nix_store_executable, "nix-store")

  defp safe_tail(output) do
    output
    |> to_string()
    |> String.replace_invalid("�")
    |> String.trim()
    |> String.slice(-500, 500)
  end
end
