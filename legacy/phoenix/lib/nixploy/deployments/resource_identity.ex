defmodule Nixploy.Deployments.ResourceIdentity do
  @moduledoc "Derives the one canonical managed resource key shared with packaged adapters."

  @safe ~r/^[a-z0-9][a-z0-9_-]{0,126}$/

  def derive(project, target) when is_binary(project) and is_binary(target) do
    identity = :crypto.hash(:sha256, project <> <<0>> <> target) |> Base.encode16(case: :lower)
    key = "nixploy-#{sanitize(project)}-#{String.slice(identity, 0, 10)}-#{sanitize(target)}"

    if Regex.match?(@safe, key), do: {:ok, key}, else: {:error, :resource_identity_invalid}
  end

  def derive(_project, _target), do: {:error, :resource_identity_invalid}

  def derive!(project, target) do
    case derive(project, target) do
      {:ok, key} -> key
      {:error, reason} -> raise ArgumentError, "invalid resource identity: #{inspect(reason)}"
    end
  end

  defp sanitize(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 48)
  end
end
