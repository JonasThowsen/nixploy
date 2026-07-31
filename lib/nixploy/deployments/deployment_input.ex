defmodule Nixploy.Deployments.DeploymentInput do
  @moduledoc "A durable immutable deployment input staging operation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "deployment_inputs" do
    field :input_kind, Ecto.Enum, values: [:local_store]
    field :store_path, :string
    field :nar_hash, :string
    field :selected_target, :string
    field :derived_snapshot, :map, default: %{}
    field :configuration_digest, :string
    field :state, Ecto.Enum, values: [:staging, :staged, :failed], default: :staging
    field :failure, :map
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :requested_by_operator, Nixploy.Accounts.Operator

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(input, attrs) do
    input
    |> cast(attrs, [
      :input_kind,
      :store_path,
      :selected_target,
      :requested_by_operator_id,
      :started_at
    ])
    |> update_change(:store_path, &trim/1)
    |> update_change(:selected_target, &trim_optional/1)
    |> validate_required([:input_kind, :store_path, :requested_by_operator_id, :started_at])
    |> validate_length(:store_path, max: 4_096)
    |> validate_length(:selected_target, max: 255)
    |> assoc_constraint(:requested_by_operator)
  end

  @doc false
  def staged_changeset(%__MODULE__{state: :staging} = input, attrs) do
    input
    |> cast(attrs, [
      :nar_hash,
      :selected_target,
      :derived_snapshot,
      :configuration_digest,
      :state,
      :finished_at
    ])
    |> validate_required([
      :nar_hash,
      :selected_target,
      :derived_snapshot,
      :configuration_digest,
      :state,
      :finished_at
    ])
    |> validate_inclusion(:state, [:staged])
    |> validate_length(:nar_hash, max: 255)
    |> validate_length(:selected_target, max: 255)
    |> validate_length(:configuration_digest, is: 64)
    |> validate_change(:derived_snapshot, fn :derived_snapshot, snapshot ->
      if is_map(snapshot) and map_size(snapshot) > 0,
        do: [],
        else: [derived_snapshot: "must contain normalized flake-derived configuration"]
    end)
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
