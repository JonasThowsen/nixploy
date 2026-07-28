defmodule Nixploy.LocalHost do
  @moduledoc "Discovers workloads owned by the local Podman user."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  defmodule Inventory do
    @moduledoc false
    defstruct [:hostname, :runtime_user, :observed_at, workloads: []]

    @type t :: %__MODULE__{
            hostname: String.t(),
            runtime_user: String.t(),
            observed_at: DateTime.t(),
            workloads: [Nixploy.LocalHost.Workload.t()]
          }
  end

  defmodule Workload do
    @moduledoc false
    defstruct [
      :id,
      :name,
      :image,
      :state,
      :status,
      :pod,
      :project,
      :target,
      :revision,
      :repository,
      :deployed_at,
      :slot,
      managed?: false
    ]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            name: String.t(),
            image: String.t() | nil,
            state: String.t() | nil,
            status: String.t() | nil,
            pod: String.t() | nil,
            project: String.t() | nil,
            target: String.t() | nil,
            revision: String.t() | nil,
            repository: String.t() | nil,
            deployed_at: String.t() | nil,
            slot: String.t() | nil,
            managed?: boolean()
          }
  end

  @command_timeout :timer.seconds(15)

  @spec inventory(keyword()) :: {:ok, Inventory.t()} | {:error, term()}
  def inventory(opts \\ []) do
    executable = Application.get_env(:nixploy, :podman_executable, "podman")
    execute = Keyword.get(opts, :execute, &Execution.run/2)

    command = %Command{
      executable: executable,
      args: ["ps", "-a", "--format", "json"],
      timeout: @command_timeout,
      max_output_bytes: 1_048_576
    }

    with {:ok, %{exit_status: 0, output_truncated?: false, output_tail: output}} <-
           execute.(command, []),
         {:ok, workloads} <- decode(output) do
      {:ok,
       %Inventory{
         hostname: hostname(),
         runtime_user: runtime_user(),
         observed_at: DateTime.utc_now(),
         workloads: workloads
       }}
    else
      {:ok, %{exit_status: 0, output_truncated?: true}} ->
        {:error, :podman_inventory_too_large}

      {:ok, result} ->
        {:error, {:podman_failed, result.exit_status, result.output_tail}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def decode(output) do
    case Jason.decode(output) do
      {:ok, containers} when is_list(containers) ->
        workloads =
          containers
          |> Enum.map(&workload/1)
          |> Enum.sort_by(&{not &1.managed?, &1.state != "running", &1.name})

        {:ok, workloads}

      {:ok, _other} ->
        {:error, :unexpected_podman_json}

      {:error, error} ->
        {:error, {:invalid_podman_json, Exception.message(error)}}
    end
  end

  defp workload(container) do
    labels = value(container, "Labels") || %{}
    project = label(labels, ["io.nixploy.project", "nixploy.project"])
    managed? = label(labels, ["io.nixploy.managed"]) == "true" or is_binary(project)
    name = container_name(container)

    %Workload{
      id: value(container, "Id") || value(container, "ID"),
      name: name,
      image: value(container, "Image"),
      state: value(container, "State"),
      status: value(container, "Status"),
      pod: value(container, "PodName") || value(container, "Pod"),
      project: project,
      target: label(labels, ["io.nixploy.target", "nixploy.target"]),
      revision:
        label(labels, [
          "org.opencontainers.image.revision",
          "io.nixploy.revision",
          "nixploy.git_commit"
        ]),
      repository:
        label(labels, [
          "org.opencontainers.image.source",
          "io.nixploy.repository",
          "nixploy.repository"
        ]),
      deployed_at: label(labels, ["io.nixploy.deployed_at", "nixploy.deployed_at"]),
      slot: label(labels, ["io.nixploy.slot"]) || slot_from_name(name),
      managed?: managed?
    }
  end

  defp container_name(container) do
    case value(container, "Names") || value(container, "Name") do
      [name | _rest] when is_binary(name) -> name
      name when is_binary(name) -> name
      _other -> short_id(value(container, "Id") || value(container, "ID"))
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, String.downcase(key))

  defp label(labels, keys) when is_map(labels) do
    Enum.find_value(keys, &Map.get(labels, &1))
  end

  defp label(_labels, _keys), do: nil

  defp slot_from_name(name) when is_binary(name) do
    cond do
      String.ends_with?(name, "-blue") -> "blue"
      String.ends_with?(name, "-green") -> "green"
      true -> nil
    end
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_id(_id), do: "unknown"

  defp hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      {:error, _reason} -> "unknown"
    end
  end

  defp runtime_user do
    System.get_env("USER") || System.get_env("LOGNAME") || "unknown"
  end
end
