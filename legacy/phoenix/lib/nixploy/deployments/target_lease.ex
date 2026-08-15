defmodule Nixploy.Deployments.TargetLease do
  @moduledoc "A renewable PostgreSQL lease serializing mutations for one target."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Nixploy.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  # TODO(tracer): Propagate the fencing token through native remote mutation
  # adapters so a stale process is rejected by the target as well as PostgreSQL.
  @lease_seconds 30
  @heartbeat_interval_ms :timer.seconds(10)

  schema "target_leases" do
    field :owner_id, Ecto.UUID
    field :fencing_token, :integer
    field :heartbeat_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :target, Nixploy.Fleet.Target
    belongs_to :deployment, Nixploy.Deployments.Deployment
  end

  def acquire(target_id, deployment_id) do
    owner_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # Serialize creation as well as takeover when no row exists yet.
      _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [target_id])

      case locked_lease(target_id) do
        nil ->
          insert_lease!(target_id, deployment_id, owner_id, 1, now)

        lease ->
          if DateTime.compare(lease.expires_at, now) in [:lt, :eq],
            do: renew_owner!(lease, deployment_id, owner_id, now),
            else: Repo.rollback(:target_busy)
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

    last_heartbeat = Process.get(key)

    if is_nil(last_heartbeat) or now_ms - last_heartbeat >= @heartbeat_interval_ms do
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

  defp locked_lease(target_id) do
    __MODULE__
    |> where([lease], lease.target_id == ^target_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp insert_lease!(target_id, deployment_id, owner_id, fencing_token, now) do
    %__MODULE__{}
    |> changeset(%{
      target_id: target_id,
      deployment_id: deployment_id,
      owner_id: owner_id,
      fencing_token: fencing_token,
      heartbeat_at: now,
      expires_at: expires_at(now)
    })
    |> Repo.insert!()
  end

  defp renew_owner!(lease, deployment_id, owner_id, now) do
    lease
    |> changeset(%{
      deployment_id: deployment_id,
      owner_id: owner_id,
      fencing_token: lease.fencing_token + 1,
      heartbeat_at: now,
      expires_at: expires_at(now)
    })
    |> Repo.update!()
  end

  defp changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :target_id,
      :deployment_id,
      :owner_id,
      :fencing_token,
      :heartbeat_at,
      :expires_at
    ])
    |> validate_required([
      :target_id,
      :deployment_id,
      :owner_id,
      :fencing_token,
      :heartbeat_at,
      :expires_at
    ])
    |> validate_number(:fencing_token, greater_than: 0)
    |> unique_constraint(:target_id)
    |> assoc_constraint(:target)
    |> assoc_constraint(:deployment)
  end

  defp expires_at(now), do: DateTime.add(now, @lease_seconds, :second)
end
