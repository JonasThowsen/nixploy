defmodule Nixploy.Applications.Service do
  @moduledoc "A repository application attached to a deployment target."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "services" do
    field :name, :string
    field :flake_output, :string, default: "docker"
    field :domain, :string
    field :health_path, :string, default: "/health"

    belongs_to :repository, Nixploy.Applications.Repository
    belongs_to :target, Nixploy.Fleet.Target
    has_many :deployments, Nixploy.Deployments.Deployment

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service, attrs) do
    service
    |> cast(attrs, [
      :name,
      :flake_output,
      :domain,
      :health_path,
      :repository_id,
      :target_id
    ])
    |> trim_fields([:name, :flake_output, :domain, :health_path])
    |> empty_domain_to_nil()
    |> validate_required([:name, :flake_output, :health_path, :repository_id, :target_id])
    |> validate_format(:domain, ~r/^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$/,
      message: "must be a hostname without a scheme or path"
    )
    |> validate_format(:health_path, ~r|^/|, message: "must start with /")
    |> assoc_constraint(:repository)
    |> assoc_constraint(:target)
    |> unique_constraint([:target_id, :name])
    |> unique_constraint(:domain)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      update_change(acc, field, &trim/1)
    end)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp empty_domain_to_nil(changeset) do
    case get_change(changeset, :domain) do
      "" -> put_change(changeset, :domain, nil)
      _domain -> changeset
    end
  end
end
