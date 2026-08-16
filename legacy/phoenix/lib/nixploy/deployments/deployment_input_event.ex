defmodule Nixploy.Deployments.DeploymentInputEvent do
  @moduledoc "Append-only durable progress for release preparation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "deployment_input_events" do
    field :stage, :string
    field :level, Ecto.Enum, values: [:info, :warning, :error], default: :info
    field :message, :string
    field :metadata, :map, default: %{}
    belongs_to :deployment_input, Nixploy.Deployments.DeploymentInput
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:deployment_input_id, :stage, :level, :message, :metadata, :inserted_at])
    |> validate_required([:deployment_input_id, :stage, :level, :message, :inserted_at])
    |> validate_length(:stage, max: 64)
    |> validate_length(:message, max: 2_000)
    |> assoc_constraint(:deployment_input)
  end
end
