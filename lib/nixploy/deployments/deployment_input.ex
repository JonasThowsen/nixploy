defmodule Nixploy.Deployments.DeploymentInput do
  @moduledoc "A durable immutable deployment input staging or main preparation operation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "deployment_inputs" do
    field :input_kind, Ecto.Enum, values: [:local_store, :git_main]
    field :registration_channel, Ecto.Enum, values: [:operator, :ci], default: :operator
    field :application_key, :string
    field :source_repository, :string
    field :source_ref, :string
    field :source_revision, :string
    field :repository_subdirectory, :string
    field :commit_subject, :string
    field :commit_timestamp, :utc_datetime_usec
    field :store_path, :string
    field :nar_hash, :string
    field :selected_target, :string
    field :derived_snapshot, :map, default: %{}
    field :configuration_digest, :string
    field :state, Ecto.Enum, values: [:staging, :staged, :failed], default: :staging
    field :failure, :map
    field :requested_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :requested_by_operator, Nixploy.Accounts.Operator
    has_many :events, Nixploy.Deployments.DeploymentInputEvent

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(input, attrs) do
    input
    |> cast(attrs, [
      :input_kind,
      :registration_channel,
      :source_repository,
      :source_revision,
      :store_path,
      :selected_target,
      :requested_by_operator_id,
      :started_at
    ])
    |> update_change(:store_path, &trim/1)
    |> update_change(:selected_target, &trim_optional/1)
    |> validate_required([
      :input_kind,
      :registration_channel,
      :store_path,
      :requested_by_operator_id,
      :started_at
    ])
    |> validate_length(:store_path, max: 4_096)
    |> validate_length(:selected_target, max: 255)
    |> validate_format(:source_repository, ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/)
    |> validate_format(:source_revision, ~r/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/)
    |> validate_ci_provenance()
    |> assoc_constraint(:requested_by_operator)
  end

  @doc false
  def create_main_changeset(input, attrs) do
    input
    |> cast(attrs, [
      :input_kind,
      :registration_channel,
      :application_key,
      :source_repository,
      :source_ref,
      :repository_subdirectory,
      :selected_target,
      :requested_by_operator_id,
      :requested_at,
      :started_at
    ])
    |> validate_required([
      :input_kind,
      :registration_channel,
      :application_key,
      :source_repository,
      :source_ref,
      :repository_subdirectory,
      :selected_target,
      :requested_by_operator_id,
      :requested_at
    ])
    |> validate_inclusion(:input_kind, [:git_main])
    |> validate_inclusion(:source_ref, ["refs/heads/main"])
    |> validate_format(:application_key, ~r/^[a-z0-9][a-z0-9_-]{0,62}$/)
    |> validate_format(:source_repository, ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/)
    |> validate_length(:repository_subdirectory, max: 1_024)
    |> validate_length(:selected_target, max: 255)
    |> assoc_constraint(:requested_by_operator)
    |> check_constraint(:input_kind, name: :valid_direct_main_provenance)
  end

  @doc false
  def resolved_changeset(%__MODULE__{state: :staging, source_revision: nil} = input, attrs) do
    input
    |> cast(attrs, [:source_revision, :resolved_at, :started_at])
    |> validate_required([:source_revision, :resolved_at, :started_at])
    |> validate_format(:source_revision, ~r/^[0-9a-f]{40}$/)
  end

  def resolved_changeset(input, _attrs), do: invalid_terminal_changeset(input)

  @doc false
  def staged_changeset(%__MODULE__{state: :staging} = input, attrs) do
    input
    |> cast(attrs, [
      :store_path,
      :nar_hash,
      :selected_target,
      :commit_subject,
      :commit_timestamp,
      :derived_snapshot,
      :configuration_digest,
      :state,
      :finished_at
    ])
    |> validate_required([
      :store_path,
      :nar_hash,
      :selected_target,
      :derived_snapshot,
      :configuration_digest,
      :state,
      :finished_at
    ])
    |> validate_inclusion(:state, [:staged])
    |> validate_length(:store_path, max: 4_096)
    |> validate_length(:nar_hash, max: 255)
    |> validate_length(:selected_target, max: 255)
    |> validate_length(:commit_subject, max: 500)
    |> validate_length(:configuration_digest, is: 64)
    |> validate_change(:derived_snapshot, fn :derived_snapshot, snapshot ->
      if is_map(snapshot) and map_size(snapshot) > 0,
        do: [],
        else: [derived_snapshot: "must contain normalized flake-derived configuration"]
    end)
    |> unique_constraint([:store_path, :selected_target],
      name: :deployment_inputs_unique_staged_release
    )
    |> unique_constraint(
      [:application_key, :source_revision, :selected_target, :configuration_digest],
      name: :deployment_inputs_unique_direct_main_release
    )
  end

  def staged_changeset(input, _attrs), do: invalid_terminal_changeset(input)

  @doc false
  def failed_changeset(%__MODULE__{state: :staging} = input, attrs) do
    input
    |> cast(attrs, [:state, :failure, :finished_at])
    |> validate_required([:state, :failure, :finished_at])
    |> validate_inclusion(:state, [:failed])
  end

  def failed_changeset(input, _attrs), do: invalid_terminal_changeset(input)

  defp validate_ci_provenance(changeset) do
    if get_field(changeset, :registration_channel) == :ci do
      validate_required(changeset, [:source_repository, :source_revision])
    else
      changeset
    end
  end

  defp invalid_terminal_changeset(input) do
    input
    |> change()
    |> add_error(:state, "terminal deployment input cannot be changed")
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp trim_optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_optional(value), do: value
end
