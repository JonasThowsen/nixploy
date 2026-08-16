defmodule Nixploy.Tasks.TaskOperation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_operations" do
    belongs_to :native_deployment, Nixploy.Deployments.NativeDeployment
    belongs_to :deployment_input, Nixploy.Deployments.DeploymentInput
    belongs_to :requested_by_operator, Nixploy.Accounts.Operator
    field :task_name, :string
    field :description, :string
    field :confirmation, Ecto.Enum, values: [:required, :dangerous]
    field :command_digest, :string
    field :resource_key, :string
    field :state, Ecto.Enum, values: [:queued, :running, :succeeded, :failed, :cancelled]
    field :output_tail, :string
    field :output_truncated, :boolean, default: false
    field :failure, :map
    field :cancellation_requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :native_deployment_id,
      :deployment_input_id,
      :requested_by_operator_id,
      :task_name,
      :description,
      :confirmation,
      :command_digest,
      :resource_key,
      :state
    ])
    |> validate_required([
      :native_deployment_id,
      :deployment_input_id,
      :requested_by_operator_id,
      :task_name,
      :description,
      :confirmation,
      :command_digest,
      :resource_key,
      :state
    ])
    |> validate_format(:task_name, ~r/^[a-z][a-z0-9_-]{0,63}$/)
    |> validate_length(:description, max: 4_096)
    |> validate_length(:command_digest, is: 64)
    |> validate_format(:resource_key, ~r/^nixploy-[a-z0-9][a-z0-9_-]{0,126}$/)
    |> foreign_key_constraint(:native_deployment_id)
    |> foreign_key_constraint(:deployment_input_id)
    |> foreign_key_constraint(:requested_by_operator_id)
    |> unique_constraint(:resource_key, name: :one_active_task_per_resource)
  end

  def update_changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :state,
      :output_tail,
      :output_truncated,
      :failure,
      :cancellation_requested_at,
      :started_at,
      :finished_at
    ])
    |> validate_required([:state])
    |> validate_length(:output_tail, max: 65_536)
    |> check_constraint(:state, name: :valid_task_operation_state)
  end
end
