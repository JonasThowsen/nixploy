defmodule Mix.Tasks.Nixploy.Operator do
  @shortdoc "Provisions or rotates the initial nixploy operator"

  @moduledoc """
  Provisions or updates a control-plane operator.

      NIXPLOY_OPERATOR_PASSWORD='a long password' mix nixploy.operator operator@example.com

  The password is read from the environment rather than command arguments to
  avoid storing it in shell history.
  """

  use Mix.Task

  @impl Mix.Task
  def run([email]) do
    password =
      System.get_env("NIXPLOY_OPERATOR_PASSWORD") ||
        Mix.raise("NIXPLOY_OPERATOR_PASSWORD is required")

    Mix.Task.run("app.start")

    case Nixploy.Accounts.provision_operator(%{email: email, password: password}) do
      {:ok, operator} ->
        Mix.shell().info("Provisioned operator #{operator.email}")

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

        Mix.raise("could not provision operator: #{inspect(errors)}")
    end
  end

  def run(_args) do
    Mix.raise("usage: mix nixploy.operator EMAIL")
  end
end
