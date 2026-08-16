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

  defmodule HealthObservation do
    @moduledoc false
    defstruct [
      :container_id,
      :container_name,
      :container_state,
      :status,
      :endpoint,
      :status_code,
      :failure,
      :observed_at
    ]

    @type t :: %__MODULE__{
            container_id: String.t(),
            container_name: String.t(),
            container_state: String.t() | nil,
            status: :healthy | :unhealthy | :failed,
            endpoint: String.t() | nil,
            status_code: non_neg_integer() | nil,
            failure: String.t() | nil,
            observed_at: DateTime.t()
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
      :cpu_percent,
      :memory_usage,
      :memory_percent,
      :network_io,
      :block_io,
      :pids,
      :metrics_error,
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
            cpu_percent: String.t() | nil,
            memory_usage: String.t() | nil,
            memory_percent: String.t() | nil,
            network_io: String.t() | nil,
            block_io: String.t() | nil,
            pids: String.t() | nil,
            metrics_error: term() | nil,
            observed_at: DateTime.t(),
            published_ports: [String.t()],
            logs_truncated?: boolean(),
            managed?: boolean()
          }
  end

  @command_timeout :timer.seconds(15)
  @log_tail_lines 200
  @max_log_bytes 65_536
  @health_paths ["/health", "/ready"]
  @health_timeout_seconds 5
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
      details =
        details
        |> fetch_metrics(executable, container_id, execute)
        |> fetch_logs(executable, container_id, execute)

      {:ok, details}
    end
  end

  @spec observe_health(String.t(), keyword()) ::
          {:ok, HealthObservation.t()} | {:error, term()}
  def observe_health(container_id, opts \\ []) do
    podman = Application.get_env(:nixploy, :podman_executable, "podman")
    curl = Application.get_env(:nixploy, :curl_executable, "curl")
    execute = Keyword.get(opts, :execute, &Execution.run/2)

    with :ok <- validate_container_id(container_id),
         {:ok, output} <- inspect_container(podman, container_id, execute),
         {:ok, details} <- decode_details(output),
         :ok <- require_managed(details),
         {:ok, container} <- decode_inspect_container(output) do
      observe_container_health(details, container, curl, execute)
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

  defp fetch_metrics(details, executable, container_id, execute) do
    # TODO(tracer): Persist sampled metrics in a supervised observer before adding
    # charts, retention, or alerts. This first slice deliberately exposes one
    # bounded point-in-time Podman sample when an operator opens an application.
    command = %Command{
      executable: executable,
      args: ["stats", "--no-stream", "--format", "json", "--", container_id],
      timeout: @command_timeout,
      max_output_bytes: 65_536
    }

    case execute.(command, []) do
      {:ok, %{exit_status: 0, output_truncated?: false, output_tail: output}} ->
        case decode_metrics(output) do
          {:ok, metrics} -> struct!(details, metrics)
          {:error, reason} -> %{details | metrics_error: reason}
        end

      {:ok, %{exit_status: 0, output_truncated?: true}} ->
        %{details | metrics_error: :podman_stats_too_large}

      {:ok, result} ->
        %{details | metrics_error: {:podman_stats_failed, result.exit_status}}

      {:error, reason} ->
        %{details | metrics_error: {:podman_stats_failed, reason}}
    end
  end

  @doc false
  def decode_metrics(output) do
    with {:ok, decoded} <- Jason.decode(output),
         metric when is_map(metric) <- List.first(List.wrap(decoded)) do
      {:ok,
       %{
         cpu_percent: value(metric, "cpu_percent") || value(metric, "CPU"),
         memory_usage: value(metric, "mem_usage") || value(metric, "MemUsage"),
         memory_percent: value(metric, "mem_percent") || value(metric, "MemPerc"),
         network_io: value(metric, "net_io") || value(metric, "NetIO"),
         block_io: value(metric, "block_io") || value(metric, "BlockIO"),
         pids: value(metric, "pids") || value(metric, "PIDS")
       }}
    else
      {:error, error} -> {:error, {:invalid_podman_stats_json, Exception.message(error)}}
      _missing_metric -> {:error, :podman_stats_unavailable}
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

  defp observe_container_health(details, container, curl, execute) do
    observation = %HealthObservation{
      container_id: details.id,
      container_name: details.name,
      container_state: details.state,
      observed_at: DateTime.utc_now()
    }

    case {String.downcase(details.state || ""), runtime_port(container)} do
      {state, _port} when state != "running" ->
        {:ok,
         %{
           observation
           | status: :unhealthy,
             failure: "container state is #{details.state || "unknown"}"
         }}

      {"running", nil} ->
        {:ok,
         %{
           observation
           | status: :failed,
             failure: "no allowlisted local runtime port was reported"
         }}

      {"running", port} ->
        probe_health(observation, port, curl, execute)
    end
  end

  # TODO(tracer): Replace the fixed local endpoint candidates with the health
  # path derived from the project flake before supporting arbitrary paths.
  defp probe_health(observation, port, curl, execute) do
    Enum.reduce_while(@health_paths, [], fn path, failures ->
      endpoint = "http://127.0.0.1:#{port}#{path}"

      command = %Command{
        executable: curl,
        args: [
          "--silent",
          "--show-error",
          "--output",
          "/dev/null",
          "--write-out",
          "%{http_code}",
          "--max-time",
          Integer.to_string(@health_timeout_seconds),
          "--",
          endpoint
        ],
        timeout: :timer.seconds(@health_timeout_seconds + 2),
        max_output_bytes: 4_096
      }

      case execute.(command, []) do
        {:ok, %{exit_status: 0, output_tail: output}} ->
          case Integer.parse(String.trim(output)) do
            {status, ""} when status in 200..299 ->
              {:halt,
               {:ok,
                %{
                  observation
                  | status: :healthy,
                    endpoint: endpoint,
                    status_code: status,
                    observed_at: DateTime.utc_now()
                }}}

            {status, ""} ->
              {:cont, [{endpoint, status} | failures]}

            _invalid ->
              {:halt,
               {:ok,
                %{
                  observation
                  | status: :failed,
                    endpoint: endpoint,
                    failure: "health probe returned an invalid HTTP status",
                    observed_at: DateTime.utc_now()
                }}}
          end

        {:ok, result} ->
          {:halt,
           {:ok,
            %{
              observation
              | status: :failed,
                endpoint: endpoint,
                failure: "health probe exited with status #{result.exit_status}",
                observed_at: DateTime.utc_now()
            }}}

        {:error, :timeout} ->
          {:halt,
           {:ok,
            %{
              observation
              | status: :failed,
                endpoint: endpoint,
                failure: "health probe timed out after 7 seconds",
                observed_at: DateTime.utc_now()
            }}}

        {:error, reason} ->
          {:halt,
           {:ok,
            %{
              observation
              | status: :failed,
                endpoint: endpoint,
                failure: health_execution_error(reason),
                observed_at: DateTime.utc_now()
            }}}
      end
    end)
    |> case do
      {:ok, observation} ->
        {:ok, observation}

      failures when is_list(failures) ->
        failures = Enum.reverse(failures)
        {endpoint, status_code} = List.last(failures)

        reason =
          Enum.map_join(failures, "; ", fn {url, status} ->
            "#{URI.parse(url).path} returned HTTP #{status}"
          end)

        {:ok,
         %{
           observation
           | status: :unhealthy,
             endpoint: endpoint,
             status_code: status_code,
             failure: reason,
             observed_at: DateTime.utc_now()
         }}
    end
  end

  defp runtime_port(container) do
    published_runtime_port(container) || environment_runtime_port(container)
  end

  defp published_runtime_port(container) do
    ports =
      container
      |> value("NetworkSettings")
      |> value("Ports")

    if is_map(ports) do
      ports
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.map(&published_binding_port/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()
      |> List.first()
    end
  end

  defp published_binding_port(binding) do
    if value(binding, "HostIp") in [nil, "", "0.0.0.0", "127.0.0.1"] do
      parse_port(value(binding, "HostPort"))
    end
  end

  defp environment_runtime_port(container) do
    container
    |> value("Config")
    |> value("Env")
    |> List.wrap()
    |> Enum.find_value(fn
      "PORT=" <> port -> parse_port(port)
      _environment_entry -> nil
    end)
  end

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {port, ""} when port in 1..65_535 -> port
      _invalid -> nil
    end
  end

  defp parse_port(_port), do: nil

  defp health_execution_error({:executable_not_found, executable}),
    do: "#{executable} is not available to the nixploy service"

  defp health_execution_error(reason), do: "health probe failed: #{inspect(reason)}"

  defp require_managed(%WorkloadDetails{managed?: true}), do: :ok
  defp require_managed(_details), do: {:error, :unmanaged_workload}

  defp decode_inspect_container(output) do
    case Jason.decode(output) do
      {:ok, [container]} when is_map(container) -> {:ok, container}
      {:ok, _other} -> {:error, :unexpected_podman_inspect_json}
      {:error, error} -> {:error, {:invalid_podman_inspect_json, Exception.message(error)}}
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
