defmodule Nixploy.Deployments.Event do
  @moduledoc "An append-only deployment progress event."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "deployment_events" do
    field :level, Ecto.Enum, values: [:debug, :info, :warning, :error], default: :info
    field :stage, :string
    field :message, :string
    field :metadata, :map, default: %{}

    belongs_to :deployment, Nixploy.Deployments.Deployment

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:deployment_id, :level, :stage, :message, :metadata])
    |> validate_required([:deployment_id, :level, :stage, :message])
    |> assoc_constraint(:deployment)
    |> check_constraint(:level, name: :valid_level)
  end
end
