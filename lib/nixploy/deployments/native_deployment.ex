defmodule Nixploy.Deployments.NativeDeployment do
  @moduledoc "A durable native local blue/green deployment operation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [
    :queued,
    :preparing,
    :building,
    :loading,
    :installing_credentials,
    :preparing_slot,
    :pre_starting,
    :starting,
    :health_checking,
    :switching,
    :verifying,
    :succeeded,
    :failed,
    :cancelled
  ]
  @terminal_states [:succeeded, :failed, :cancelled]

  @type t :: %__MODULE__{}

  schema "native_deployments" do
    field :project, :string
    field :target, :string
    field :operation_kind, Ecto.Enum, values: [:deploy, :rollback], default: :deploy
    field :state, Ecto.Enum, values: @states, default: :queued
    field :current_stage, Ecto.Enum, values: @states, default: :queued
    field :resource_prefix, :string
    field :fencing_token, :integer
    field :previous_upstream, :string
    field :selected_slot, :string
    field :selected_port, :integer
    field :image_store_path, :string
    field :image_reference, :string
    field :image_id, :string
    field :container_name, :string
    field :container_id, :string
    field :verified_upstream, :string
    field :failure, :map
    field :cancellation_requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :deployment_input, Nixploy.Deployments.DeploymentInput
    belongs_to :requested_by_operator, Nixploy.Accounts.Operator
    belongs_to :rollback_of, __MODULE__
    belongs_to :retry_of, __MODULE__
    field :expected_image_id, :string
    field :expected_slot, :string
    has_many :events, Nixploy.Deployments.NativeEvent

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  @doc false
  def create_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :deployment_input_id,
      :requested_by_operator_id,
      :project,
      :target,
      :operation_kind,
      :resource_prefix,
      :rollback_of_id,
      :retry_of_id,
      :expected_image_id,
      :expected_slot
    ])
    |> validate_required([
      :deployment_input_id,
      :requested_by_operator_id,
      :project,
      :target,
      :resource_prefix
    ])
    |> validate_length(:project, max: 4_096)
    |> validate_length(:target, max: 255)
    |> validate_format(:resource_prefix, ~r/^nixploy-[a-z0-9][a-z0-9_-]{0,126}$/)
    |> validate_inclusion(:expected_slot, ["blue", "green"])
    |> assoc_constraint(:deployment_input)
    |> assoc_constraint(:requested_by_operator)
    |> assoc_constraint(:rollback_of)
    |> assoc_constraint(:retry_of)
    |> check_constraint(:operation_kind, name: :valid_native_operation_kind)
    |> check_constraint(:operation_kind, name: :valid_native_rollback_identity)
    |> unique_constraint([:project, :target], name: :one_active_native_deployment_per_target)
  end

  @doc false
  def transition_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :state,
      :current_stage,
      :resource_prefix,
      :fencing_token,
      :previous_upstream,
      :selected_slot,
      :selected_port,
      :image_store_path,
      :image_reference,
      :image_id,
      :container_name,
      :container_id,
      :verified_upstream,
      :failure,
      :started_at,
      :finished_at
    ])
    |> validate_required([:state, :current_stage])
    |> validate_inclusion(:selected_slot, ["blue", "green"])
    |> validate_number(:fencing_token, greater_than: 0)
    |> check_constraint(:state, name: :valid_native_deployment_state)
    |> check_constraint(:fencing_token, name: :valid_native_fencing_token)
  end

  @doc false
  def cancellation_changeset(deployment, requested_at) do
    change(deployment, cancellation_requested_at: requested_at)
  end
end
