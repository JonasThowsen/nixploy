defmodule Nixploy.Deployments.NativeTargetLease do
  @moduledoc "A renewable PostgreSQL fencing lease for one canonical native resource key."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Nixploy.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @lease_seconds 30
  @heartbeat_interval_ms :timer.seconds(10)

  schema "native_target_leases" do
    field :resource_key, :string
    field :owner_id, Ecto.UUID
    field :fencing_token, :integer
    field :heartbeat_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    belongs_to :native_deployment, Nixploy.Deployments.NativeDeployment
    timestamps(type: :utc_datetime_usec)
  end

  def acquire(resource_key, deployment_id) do
    owner_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [resource_key])

      case locked_lease(resource_key) do
        nil -> insert_lease!(resource_key, deployment_id, owner_id, 1, now)
        lease -> acquire_existing!(lease, deployment_id, owner_id, now)
      end
    end)
    |> case do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, reason}
    end
  end

  def maintain(%__MODULE__{} = lease) do
    key = {__MODULE__, lease.id}
    now_ms = System.monotonic_time(:millisecond)

    if is_nil(Process.get(key)) or now_ms - Process.get(key) >= @heartbeat_interval_ms do
      case heartbeat(lease) do
        :ok ->
          Process.put(key, now_ms)
          :ok

        {:error, :lease_lost} = error ->
          error
      end
    else
      :ok
    end
  end

  def release(%__MODULE__{} = lease) do
    Process.delete({__MODULE__, lease.id})
    now = DateTime.utc_now()

    __MODULE__
    |> where([held], held.id == ^lease.id and held.owner_id == ^lease.owner_id)
    |> Repo.update_all(set: [heartbeat_at: now, expires_at: now])

    :ok
  end

  defp acquire_existing!(lease, deployment_id, owner_id, now) do
    if DateTime.compare(lease.expires_at, now) in [:lt, :eq] do
      lease
      |> changeset(%{
        native_deployment_id: deployment_id,
        owner_id: owner_id,
        fencing_token: lease.fencing_token + 1,
        heartbeat_at: now,
        expires_at: expires_at(now)
      })
      |> Repo.update!()
    else
      Repo.rollback(:target_busy)
    end
  end

  defp heartbeat(lease) do
    now = DateTime.utc_now()

    {count, _rows} =
      __MODULE__
      |> where(
        [held],
        held.id == ^lease.id and held.owner_id == ^lease.owner_id and
          held.fencing_token == ^lease.fencing_token and held.expires_at > ^now
      )
      |> Repo.update_all(set: [heartbeat_at: now, expires_at: expires_at(now)])

    if count == 1, do: :ok, else: {:error, :lease_lost}
  end

  defp locked_lease(resource_key) do
    __MODULE__
    |> where([lease], lease.resource_key == ^resource_key)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp insert_lease!(resource_key, deployment_id, owner_id, fencing_token, now) do
    %__MODULE__{}
    |> changeset(%{
      resource_key: resource_key,
      native_deployment_id: deployment_id,
      owner_id: owner_id,
      fencing_token: fencing_token,
      heartbeat_at: now,
      expires_at: expires_at(now)
    })
    |> Repo.insert!()
  end

  defp changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :resource_key,
      :native_deployment_id,
      :owner_id,
      :fencing_token,
      :heartbeat_at,
      :expires_at
    ])
    |> validate_required([
      :resource_key,
      :native_deployment_id,
      :owner_id,
      :fencing_token,
      :heartbeat_at,
      :expires_at
    ])
    |> validate_number(:fencing_token, greater_than: 0)
    |> unique_constraint(:resource_key)
    |> assoc_constraint(:native_deployment)
  end

  defp expires_at(now), do: DateTime.add(now, @lease_seconds, :second)
end
