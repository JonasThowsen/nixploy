defmodule Nixploy.Applications.Repository do
  @moduledoc "A Git repository containing deployable Nix flake outputs."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "repositories" do
    field :name, :string
    field :url, :string
    field :default_ref, :string, default: "main"
    field :subdirectory, :string, default: "."

    has_many :services, Nixploy.Applications.Service

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [:name, :url, :default_ref, :subdirectory])
    |> update_change(:name, &trim/1)
    |> update_change(:url, &trim/1)
    |> update_change(:default_ref, &trim/1)
    |> update_change(:subdirectory, &trim/1)
    |> validate_required([:name, :url, :default_ref, :subdirectory])
    |> validate_subdirectory()
    |> unique_constraint(:name)
  end

  defp validate_subdirectory(changeset) do
    validate_change(changeset, :subdirectory, fn :subdirectory, subdirectory ->
      case Path.safe_relative(subdirectory, System.tmp_dir!()) do
        {:ok, _safe_path} -> []
        :error -> [subdirectory: "must be a relative path without parent traversal"]
      end
    end)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
