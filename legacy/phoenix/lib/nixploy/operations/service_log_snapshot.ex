defmodule Nixploy.Operations.ServiceLogSnapshot do
  @moduledoc "The latest bounded active-container log snapshot for a service."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # TODO(tracer): Move retained log bodies to the artifact store and keep
  # snapshot history once retention policy replaces this single bounded value.
  schema "service_log_snapshots" do
    field :request_id, Ecto.UUID
    field :status, Ecto.Enum, values: [:pending, :available, :failed], default: :pending
    field :target_identity, :string
    field :slot, :string
    field :container_name, :string
    field :content, :string
    field :line_count, :integer
    field :truncated, :boolean, default: false
    field :failure, :map
    field :requested_at, :utc_datetime
    field :fetched_at, :utc_datetime

    belongs_to :service, Nixploy.Applications.Service

    timestamps(type: :utc_datetime)
  end

  def request_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:service_id, :request_id, :requested_at])
    |> put_change(:status, :pending)
    |> put_change(:failure, nil)
    |> validate_required([:service_id, :request_id, :status, :requested_at])
    |> assoc_constraint(:service)
    |> unique_constraint(:service_id)
    |> check_constraint(:status, name: :valid_status)
  end

  def available_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :target_identity,
      :slot,
      :container_name,
      :content,
      :line_count,
      :truncated,
      :fetched_at
    ])
    |> put_change(:status, :available)
    |> put_change(:failure, nil)
    |> validate_required([
      :status,
      :target_identity,
      :slot,
      :container_name,
      :line_count,
      :truncated,
      :fetched_at
    ])
    |> validate_number(:line_count, greater_than_or_equal_to: 0)
    |> check_constraint(:status, name: :valid_status)
  end

  def failed_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:failure, :fetched_at])
    |> put_change(:status, :failed)
    |> validate_required([:status, :failure, :fetched_at])
    |> check_constraint(:status, name: :valid_status)
  end
end
