defmodule Nixploy.Operations.ServiceObservation do
  @moduledoc "The latest worker-observed runtime state for a service."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "service_observations" do
    field :request_id, Ecto.UUID
    field :status, Ecto.Enum, values: [:pending, :available, :failed], default: :pending
    field :target_identity, :string
    field :active_slot, :string
    field :inactive_slot, :string
    field :active_container, :string
    field :active_container_state, :string
    field :inactive_container, :string
    field :inactive_container_state, :string
    field :image, :string
    field :git_commit, :string
    field :deployed_at, :utc_datetime_usec
    field :caddy_route, :string
    field :upstream, :string
    field :health_url, :string
    field :health_status, :integer
    field :health_error, :string
    field :failure, :map
    field :requested_at, :utc_datetime
    field :refreshed_at, :utc_datetime

    belongs_to :service, Nixploy.Applications.Service

    timestamps(type: :utc_datetime)
  end

  @observed_fields [
    :target_identity,
    :active_slot,
    :inactive_slot,
    :active_container,
    :active_container_state,
    :inactive_container,
    :inactive_container_state,
    :image,
    :git_commit,
    :deployed_at,
    :caddy_route,
    :upstream,
    :health_url,
    :health_status,
    :health_error
  ]

  def request_changeset(observation, attrs) do
    observation
    |> cast(attrs, [:service_id, :request_id, :requested_at])
    |> put_change(:status, :pending)
    |> put_change(:failure, nil)
    |> validate_required([:service_id, :request_id, :status, :requested_at])
    |> assoc_constraint(:service)
    |> unique_constraint(:service_id)
    |> check_constraint(:status, name: :valid_status)
  end

  def available_changeset(observation, attrs) do
    observation
    |> cast(attrs, @observed_fields ++ [:refreshed_at])
    |> put_change(:status, :available)
    |> put_change(:failure, nil)
    |> validate_required([
      :status,
      :target_identity,
      :active_slot,
      :active_container,
      :refreshed_at
    ])
    |> check_constraint(:status, name: :valid_status)
  end

  def failed_changeset(observation, attrs) do
    observation
    |> cast(attrs, [:failure, :refreshed_at])
    |> put_change(:status, :failed)
    |> validate_required([:status, :failure, :refreshed_at])
    |> check_constraint(:status, name: :valid_status)
  end
end
