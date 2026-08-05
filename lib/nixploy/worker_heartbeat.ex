defmodule Nixploy.WorkerHeartbeat do
  @moduledoc "Persists bounded worker liveness without exposing credential paths or values."

  use GenServer
  use Ecto.Schema
  import Ecto.{Changeset, Query}
  require Logger

  alias Nixploy.Repo

  @primary_key {:runtime_id, Ecto.UUID, autogenerate: false}
  schema "worker_heartbeats" do
    field :hostname, :string
    field :os_pid, :integer
    field :capabilities, :map
    field :started_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
  end

  @interval :timer.seconds(10)
  @stale_after :timer.seconds(30)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def latest do
    __MODULE__
    |> order_by([heartbeat], desc: heartbeat.last_seen_at)
    |> limit(1)
    |> Repo.one()
  end

  def available?(heartbeat \\ latest())
  def available?(nil), do: false

  def available?(%__MODULE__{last_seen_at: seen}) do
    DateTime.diff(DateTime.utc_now(), seen, :millisecond) <= @stale_after
  end

  @doc false
  def record(runtime_id, started_at, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    attrs = %{
      runtime_id: runtime_id,
      hostname: Keyword.get_lazy(opts, :hostname, &hostname/0),
      os_pid: Keyword.get_lazy(opts, :os_pid, &os_pid/0),
      capabilities: %{
        "remote_cli" => configured?(:remote_cli_executable),
        "deployment_policy" => configured?(:deployment_policy_component),
        "sops_identity" => is_binary(System.get_env("SOPS_AGE_KEY_FILE")),
        "ssh_identity" => is_binary(System.get_env("NIXPLOY_SSH_IDENTITY_FILE"))
      },
      started_at: started_at,
      last_seen_at: now
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [last_seen_at: now, capabilities: attrs.capabilities]],
      conflict_target: :runtime_id,
      returning: true
    )
  end

  @impl true
  def init(_opts) do
    now = DateTime.utc_now()
    state = %{runtime_id: Ecto.UUID.generate(), started_at: now}
    send(self(), :heartbeat)
    {:ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    case record(state.runtime_id, state.started_at) do
      {:ok, _heartbeat} ->
        :ok

      {:error, changeset} ->
        Logger.error("worker heartbeat failed: #{inspect(changeset.errors)}")
    end

    Process.send_after(self(), :heartbeat, @interval)
    {:noreply, state}
  end

  defp changeset(heartbeat, attrs) do
    heartbeat
    |> cast(attrs, [:runtime_id, :hostname, :os_pid, :capabilities, :started_at, :last_seen_at])
    |> validate_required([
      :runtime_id,
      :hostname,
      :os_pid,
      :capabilities,
      :started_at,
      :last_seen_at
    ])
    |> validate_length(:hostname, max: 255)
  end

  defp configured?(key) do
    case Application.get_env(:nixploy, key) do
      path when is_binary(path) -> String.starts_with?(path, "/nix/store/")
      _path -> false
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _error -> "unknown"
    end
  end

  defp os_pid, do: System.pid() |> String.to_integer()
end
