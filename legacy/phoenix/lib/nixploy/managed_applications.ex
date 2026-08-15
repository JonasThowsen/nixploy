defmodule Nixploy.ManagedApplications do
  @moduledoc "Bounded NixOS-owned application source mappings for direct-main releases."

  @source_ref "refs/heads/main"
  @key ~r/^[a-z0-9][a-z0-9_-]{0,62}$/
  @identity ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

  defmodule Application do
    @moduledoc false
    @enforce_keys [:key, :project, :target, :repository, :repository_identity]
    defstruct [
      :key,
      :project,
      :target,
      :repository,
      :repository_identity,
      :credential_path,
      subdirectory: ".",
      source_ref: "refs/heads/main"
    ]
  end

  def list do
    :nixploy
    |> Elixir.Application.get_env(:managed_applications, %{})
    |> Enum.map(fn {key, attrs} -> normalize!(to_string(key), attrs) end)
    |> Enum.sort_by(& &1.key)
  end

  def fetch(key) when is_binary(key) do
    case Enum.find(list(), &(&1.key == key)) do
      nil -> {:error, :managed_application_not_found}
      application -> {:ok, application}
    end
  end

  def fetch(_key), do: {:error, :managed_application_not_found}
  def source_ref, do: @source_ref

  defp normalize!(key, attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {name, value} -> {to_string(name), value} end)
    project = required!(attrs, "project")
    target = required!(attrs, "target")
    repository = required!(attrs, "repository")
    identity = required!(attrs, "repository_identity")
    subdirectory = Map.get(attrs, "subdirectory", ".")

    unless Regex.match?(@key, key), do: raise("invalid managed application key #{inspect(key)}")
    unless Regex.match?(@identity, identity), do: raise("invalid repository identity for #{key}")
    validate_value!(project, "project", key, 255)
    validate_value!(target, "target", key, 255)
    validate_repository_path!(repository, key)
    validate_subdirectory!(subdirectory, key)

    %Application{
      key: key,
      project: project,
      target: target,
      repository: repository,
      repository_identity: identity,
      subdirectory: subdirectory,
      credential_path: optional(attrs, "credential_path")
    }
  end

  defp required!(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "managed application #{key} is required"
    end
  end

  defp optional(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp validate_value!(value, field, key, max) do
    if byte_size(value) > max or String.contains?(value, <<0>>),
      do: raise("invalid managed application #{field} for #{key}")
  end

  defp validate_repository_path!(value, key) do
    valid? =
      is_binary(value) and value != "" and byte_size(value) <= 4_096 and
        Path.type(value) == :absolute and not String.contains?(value, <<0>>)

    unless valid?, do: raise("invalid managed application repository path for #{key}")
  end

  defp validate_subdirectory!(value, key) do
    valid? =
      is_binary(value) and value != "" and byte_size(value) <= 1_024 and
        Path.type(value) == :relative and
        Path.expand(value, "/source") |> String.starts_with?("/source") and
        not String.contains?(value, <<0>>)

    unless valid?, do: raise("invalid managed application subdirectory for #{key}")
  end
end
