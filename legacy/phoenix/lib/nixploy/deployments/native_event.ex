defmodule Nixploy.Deployments.NativeEvent do
  @moduledoc "Append-only progress evidence for a native deployment."

  use Ecto.Schema
  import Ecto.Changeset

  schema "native_deployment_events" do
    field :stage, :string
    field :level, Ecto.Enum, values: [:info, :warning, :error], default: :info
    field :message, :string
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime_usec

    belongs_to :native_deployment, Nixploy.Deployments.NativeDeployment, type: :binary_id
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :native_deployment_id,
      :stage,
      :level,
      :message,
      :metadata,
      :inserted_at
    ])
    |> validate_required([:native_deployment_id, :stage, :level, :message, :inserted_at])
    |> validate_length(:message, max: 2_000)
    |> assoc_constraint(:native_deployment)
  end
end
