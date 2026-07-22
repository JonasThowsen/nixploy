defmodule Nixploy.Fleet.Target do
  @moduledoc "A Podman-capable server reachable by deployment workers."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "targets" do
    field :name, :string
    field :host, :string
    field :ssh_port, :integer, default: 22
    field :ssh_user, :string, default: "root"

    has_many :services, Nixploy.Applications.Service

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(target, attrs) do
    target
    |> cast(attrs, [:name, :host, :ssh_port, :ssh_user])
    |> update_change(:name, &trim/1)
    |> update_change(:host, &trim/1)
    |> update_change(:ssh_user, &trim/1)
    |> validate_required([:name, :host, :ssh_port, :ssh_user])
    |> validate_format(:host, ~r/^[a-zA-Z0-9._:-]+$/, message: "must be a hostname or IP address")
    |> validate_format(:ssh_user, ~r/^[a-zA-Z_][a-zA-Z0-9_-]*\$?$/,
      message: "must be a valid SSH user"
    )
    |> validate_number(:ssh_port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> unique_constraint(:name)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
