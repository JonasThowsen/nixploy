defmodule Nixploy.RuntimeLogSnapshot do
  @moduledoc "One generation-fenced, short-lived managed-container log snapshot."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runtime_log_snapshots" do
    field :application_key, :string
    field :request_id, Ecto.UUID
    field :status, Ecto.Enum, values: [:pending, :available, :failed], default: :pending
    field :content, :string
    field :line_count, :integer
    field :truncated, :boolean, default: false
    field :failure, :map
    field :requested_at, :utc_datetime_usec
    field :fetched_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :native_deployment, Nixploy.Deployments.NativeDeployment

    timestamps(type: :utc_datetime_usec)
  end

  def request_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :application_key,
      :native_deployment_id,
      :request_id,
      :requested_at
    ])
    |> put_change(:status, :pending)
    |> put_change(:content, nil)
    |> put_change(:line_count, nil)
    |> put_change(:truncated, false)
    |> put_change(:failure, nil)
    |> put_change(:fetched_at, nil)
    |> put_change(:expires_at, nil)
    |> validate_required([
      :application_key,
      :native_deployment_id,
      :request_id,
      :requested_at,
      :status
    ])
    |> validate_format(:application_key, ~r/^[a-z0-9][a-z0-9_-]{0,62}$/)
    |> unique_constraint(:application_key)
    |> assoc_constraint(:native_deployment)
    |> check_constraint(:status, name: :valid_runtime_log_status)
  end

  def available_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:content, :line_count, :truncated, :fetched_at, :expires_at])
    |> put_change(:status, :available)
    |> put_change(:failure, nil)
    |> validate_required([:status, :line_count, :truncated, :fetched_at, :expires_at])
    |> validate_length(:content, max: 60_000, count: :bytes)
    |> validate_number(:line_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 200)
    |> check_constraint(:status, name: :valid_runtime_log_status)
    |> check_constraint(:content, name: :valid_runtime_log_size)
  end

  def failed_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:failure, :fetched_at, :expires_at])
    |> put_change(:status, :failed)
    |> put_change(:content, nil)
    |> put_change(:line_count, nil)
    |> put_change(:truncated, false)
    |> validate_required([:status, :failure, :fetched_at, :expires_at])
    |> check_constraint(:status, name: :valid_runtime_log_status)
  end
end
