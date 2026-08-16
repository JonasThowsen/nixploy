defmodule Nixploy.Deployments.Deployment do
  @moduledoc "A durable request to deploy one service revision."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [
    :queued,
    :preparing,
    :building,
    :deploying,
    :verifying,
    :succeeded,
    :failed,
    :cancelled
  ]
  @terminal_states [:succeeded, :failed, :cancelled]

  @type t :: %__MODULE__{}

  schema "deployments" do
    field :requested_ref, :string
    field :resolved_commit, :string
    field :service_snapshot, :map, default: %{}
    field :configuration_digest, :string
    field :state, Ecto.Enum, values: @states, default: :queued
    field :current_stage, Ecto.Enum, values: @states, default: :queued
    field :cancellation_requested_at, :utc_datetime
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :failure, :map

    belongs_to :service, Nixploy.Applications.Service
    belongs_to :requested_by_operator, Nixploy.Accounts.Operator
    belongs_to :cancellation_requested_by_operator, Nixploy.Accounts.Operator
    belongs_to :retry_of_deployment, __MODULE__
    has_many :events, Nixploy.Deployments.Event
    has_one :output, Nixploy.Deployments.Output

    timestamps(type: :utc_datetime)
  end

  @spec states() :: [atom()]
  def states, do: @states

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  @doc false
  def create_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :service_id,
      :requested_ref,
      :service_snapshot,
      :requested_by_operator_id,
      :retry_of_deployment_id
    ])
    |> update_change(:requested_ref, &trim/1)
    |> validate_required([:service_id, :requested_ref, :service_snapshot])
    |> validate_change(:service_snapshot, fn :service_snapshot, snapshot ->
      if map_size(snapshot) > 0,
        do: [],
        else: [service_snapshot: "must capture deployment inputs"]
    end)
    |> assoc_constraint(:service)
    |> assoc_constraint(:requested_by_operator)
    |> assoc_constraint(:retry_of_deployment)
  end

  @doc false
  def transition_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :state,
      :current_stage,
      :resolved_commit,
      :configuration_digest,
      :started_at,
      :finished_at,
      :failure
    ])
    |> validate_required([:state, :current_stage])
    |> check_constraint(:state, name: :valid_state)
  end

  @doc false
  def cancellation_changeset(deployment, requested_at, operator_id \\ nil) do
    change(deployment,
      cancellation_requested_at: requested_at,
      cancellation_requested_by_operator_id: operator_id
    )
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
