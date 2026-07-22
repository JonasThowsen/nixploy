defmodule Nixploy.Audit.Event do
  @moduledoc "An append-only record of an operator or worker action."

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "audit_events" do
    field :action, :string
    field :resource_type, :string
    field :resource_id, :string
    field :outcome, :string, default: "succeeded"
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :operator, Nixploy.Accounts.Operator
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :operator_id,
      :action,
      :resource_type,
      :resource_id,
      :outcome,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:action, :resource_type, :resource_id, :outcome, :occurred_at])
    |> validate_inclusion(:outcome, ["succeeded", "failed", "requested"])
    |> assoc_constraint(:operator)
  end
end
