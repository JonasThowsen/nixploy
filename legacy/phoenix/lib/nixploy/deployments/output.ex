defmodule Nixploy.Deployments.Output do
  @moduledoc "The bounded retained output tail for one deployment."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "deployment_outputs" do
    field :content, :string, default: ""
    field :line_count, :integer, default: 0
    field :truncated, :boolean, default: false

    belongs_to :deployment, Nixploy.Deployments.Deployment

    timestamps(type: :utc_datetime)
  end

  def changeset(output, attrs) do
    output
    |> cast(attrs, [:deployment_id, :content, :line_count, :truncated])
    |> validate_required([:deployment_id, :line_count, :truncated])
    |> validate_number(:line_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:deployment)
    |> unique_constraint(:deployment_id)
  end
end
