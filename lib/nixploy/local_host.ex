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

  defmodule WorkloadDetails do
    @moduledoc false
    defstruct [
      :id,
      :name,
      :image,
      :image_id,
      :state,
      :status,
      :health,
      :created_at,
      :started_at,
      :project,
      :target,
      :revision,
      :repository,
      :deployed_at,
      :slot,
      :logs,
      :log_line_count,
      :logs_error,
      :observed_at,
      published_ports: [],
      logs_truncated?: false,
      managed?: false
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            image: String.t() | nil,
            image_id: String.t() | nil,
            state: String.t() | nil,
            status: String.t() | nil,
            health: String.t() | nil,
            created_at: DateTime.t() | nil,
            started_at: DateTime.t() | nil,
            project: String.t() | nil,
            target: String.t() | nil,
            revision: String.t() | nil,
            repository: String.t() | nil,
            deployed_at: String.t() | nil,
            slot: String.t() | nil,
            logs: String.t() | nil,
            log_line_count: non_neg_integer() | nil,
            logs_error: term() | nil,
            observed_at: DateTime.t(),
            published_ports: [String.t()],
            logs_truncated?: boolean(),
            managed?: boolean()
          }
  end

  @command_timeout :timer.seconds(15)
  @log_tail_lines 200
  @max_log_bytes 65_536
  @safe_container_id ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/

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

  @spec workload_details(String.t(), keyword()) ::
          {:ok, WorkloadDetails.t()} | {:error, term()}
  def workload_details(container_id, opts \\ []) do
    executable = Application.get_env(:nixploy, :podman_executable, "podman")
    execute = Keyword.get(opts, :execute, &Execution.run/2)

    with :ok <- validate_container_id(container_id),
         {:ok, output} <- inspect_container(executable, container_id, execute),
         {:ok, details} <- decode_details(output) do
      {:ok, fetch_logs(details, executable, container_id, execute)}
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

  @doc false
  def decode_details(output) do
    with {:ok, [container]} <- Jason.decode(output),
         id when is_binary(id) <- value(container, "Id") || value(container, "ID") do
      labels = inspect_labels(container)
      project = label(labels, ["io.nixploy.project", "nixploy.project"])
      name = container_name(container)
      state = value(container, "State") || %{}

      {:ok,
       %WorkloadDetails{
         id: id,
         name: name,
         image: value(container, "ImageName") || get_in(container, ["Config", "Image"]),
         image_id: value(container, "Image"),
         state: inspect_state(state),
         status: inspect_status(state),
         health: inspect_health(state),
         created_at: parse_datetime(value(container, "Created") || value(container, "CreatedAt")),
         started_at: parse_datetime(value(state, "StartedAt")),
         project: project,
         target: label(labels, ["io.nixploy.target", "nixploy.target"]),
         revision: revision_label(labels),
         repository: repository_label(labels),
         deployed_at: label(labels, ["io.nixploy.deployed_at", "nixploy.deployed_at"]),
         slot: label(labels, ["io.nixploy.slot"]) || slot_from_name(name),
         published_ports: published_ports(container),
         observed_at: DateTime.utc_now(),
         managed?: managed?(labels, project)
       }}
    else
      {:ok, _other} -> {:error, :unexpected_podman_inspect_json}
      {:error, error} -> {:error, {:invalid_podman_inspect_json, Exception.message(error)}}
      _missing_id -> {:error, :podman_inspect_id_missing}
    end
  end

  defp workload(container) do
    labels = value(container, "Labels") || %{}
    project = label(labels, ["io.nixploy.project", "nixploy.project"])
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
      revision: revision_label(labels),
      repository: repository_label(labels),
      deployed_at: label(labels, ["io.nixploy.deployed_at", "nixploy.deployed_at"]),
      slot: label(labels, ["io.nixploy.slot"]) || slot_from_name(name),
      managed?: managed?(labels, project)
    }
  end

  defp inspect_container(executable, container_id, execute) do
    command = %Command{
      executable: executable,
      args: ["container", "inspect", "--format", "json", "--", container_id],
      timeout: @command_timeout,
      max_output_bytes: 1_048_576
    }

    case execute.(command, []) do
      {:ok, %{exit_status: 0, output_truncated?: false, output_tail: output}} ->
        {:ok, output}

      {:ok, %{exit_status: 0, output_truncated?: true}} ->
        {:error, :podman_inspect_too_large}

      {:ok, result} ->
        {:error, {:podman_inspect_failed, result.exit_status, result.output_tail}}

      {:error, reason} ->
        {:error, {:podman_inspect_failed, reason}}
    end
  end

  defp fetch_logs(details, executable, container_id, execute) do
    # TODO(tracer): Add follow mode and secret-aware redaction only after local
    # bounded snapshots prove useful; raw logs remain ephemeral LiveView state.
    command = %Command{
      executable: executable,
      args: ["logs", "--tail", Integer.to_string(@log_tail_lines), "--", container_id],
      timeout: @command_timeout,
      max_output_bytes: @max_log_bytes
    }

    case execute.(command, []) do
      {:ok, %{exit_status: 0} = result} ->
        logs = normalize_logs(result.output_tail, result.output_truncated?)

        %{
          details
          | logs: logs,
            log_line_count: line_count(logs),
            logs_truncated?: result.output_truncated?
        }

      {:ok, result} ->
        %{details | logs_error: {:podman_logs_failed, result.exit_status, result.output_tail}}

      {:error, reason} ->
        %{details | logs_error: {:podman_logs_failed, reason}}
    end
  end

  defp container_name(container) do
    case value(container, "Names") || value(container, "Name") do
      [name | _rest] when is_binary(name) -> String.trim_leading(name, "/")
      name when is_binary(name) -> String.trim_leading(name, "/")
      _other -> short_id(value(container, "Id") || value(container, "ID"))
    end
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.downcase(key))

  defp value(_value, _key), do: nil

  defp label(labels, keys) when is_map(labels) do
    Enum.find_value(keys, &Map.get(labels, &1))
  end

  defp label(_labels, _keys), do: nil

  defp managed?(labels, project),
    do: label(labels, ["io.nixploy.managed"]) == "true" or is_binary(project)

  defp revision_label(labels) do
    label(labels, [
      "org.opencontainers.image.revision",
      "io.nixploy.revision",
      "nixploy.git_commit"
    ])
  end

  defp repository_label(labels) do
    label(labels, [
      "org.opencontainers.image.source",
      "io.nixploy.repository",
      "nixploy.repository"
    ])
  end

  defp inspect_labels(container) do
    value(container, "Config")
    |> value("Labels")
    |> case do
      labels when is_map(labels) -> labels
      _labels -> %{}
    end
  end

  defp inspect_state(state), do: value(state, "Status")

  defp inspect_status(state) do
    cond do
      value(state, "Running") == true -> "running"
      is_integer(value(state, "ExitCode")) -> "exit #{value(state, "ExitCode")}"
      is_binary(value(state, "Error")) and value(state, "Error") != "" -> value(state, "Error")
      true -> value(state, "Status")
    end
  end

  defp inspect_health(state) do
    health = value(state, "Health") || value(state, "Healthcheck") || %{}
    value(health, "Status")
  end

  defp published_ports(container) do
    ports =
      container
      |> value("NetworkSettings")
      |> value("Ports")

    if is_map(ports) do
      ports
      |> Enum.flat_map(fn {container_port, bindings} ->
        Enum.map(List.wrap(bindings), &format_port_binding(container_port, &1))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()
    else
      []
    end
  end

  defp format_port_binding(container_port, binding) when is_map(binding) do
    host_port = value(binding, "HostPort")

    if is_binary(host_port) and host_port != "" do
      host_ip = value(binding, "HostIp")
      host_ip = if is_binary(host_ip) and host_ip != "", do: host_ip, else: "0.0.0.0"
      "#{host_ip}:#{host_port} → #{container_port}"
    end
  end

  defp format_port_binding(_container_port, _binding), do: nil

  defp normalize_logs(output, false), do: String.trim_trailing(output)

  defp normalize_logs(output, true) do
    output
    |> drop_partial_first_line()
    |> String.trim_trailing()
  end

  defp drop_partial_first_line(output) do
    case :binary.split(output, "\n") do
      [_partial] -> ""
      [_partial, complete] -> complete
    end
  end

  defp line_count(""), do: 0
  defp line_count(content), do: content |> String.split("\n") |> length()

  defp validate_container_id(container_id) when is_binary(container_id) do
    if Regex.match?(@safe_container_id, container_id),
      do: :ok,
      else: {:error, {:invalid_container_id, container_id}}
  end

  defp validate_container_id(container_id), do: {:error, {:invalid_container_id, container_id}}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

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
