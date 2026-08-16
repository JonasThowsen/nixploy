defmodule Nixploy.RuntimeRole do
  @moduledoc """
  Selects which parts of nixploy run in the current OS process.

  The same release can serve HTTP, execute privileged deployment work, or do
  both for a small single-node installation.
  """

  @type t :: :web | :worker | :all

  @roles [:web, :worker, :all]

  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(role) when is_binary(role) do
    normalized_role = role |> String.trim() |> String.downcase()

    case Enum.find(@roles, &(Atom.to_string(&1) == normalized_role)) do
      nil -> {:error, "expected one of: web, worker, all"}
      role -> {:ok, role}
    end
  end

  @spec parse!(String.t()) :: t()
  def parse!(role) do
    case parse(role) do
      {:ok, parsed_role} -> parsed_role
      {:error, reason} -> raise ArgumentError, "invalid NIXPLOY_ROLE #{inspect(role)}: #{reason}"
    end
  end

  @spec current() :: t()
  def current do
    Application.fetch_env!(:nixploy, :role)
  end

  @spec web?(t()) :: boolean()
  def web?(role \\ current()), do: role in [:web, :all]

  @spec worker?(t()) :: boolean()
  def worker?(role \\ current()), do: role in [:worker, :all]
end
