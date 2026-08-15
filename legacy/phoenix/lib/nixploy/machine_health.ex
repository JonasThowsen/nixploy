defmodule Nixploy.MachineHealth do
  @moduledoc "Collects a bounded point-in-time health snapshot for the local machine."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  defmodule Snapshot do
    @moduledoc false
    @type t :: %__MODULE__{}

    defstruct [
      :hostname,
      :observed_at,
      :cpu_percent,
      :cpu_count,
      :load_1,
      :load_5,
      :load_15,
      :running_processes,
      :total_processes,
      :memory_total_bytes,
      :memory_used_bytes,
      :memory_percent,
      :swap_total_bytes,
      :swap_used_bytes,
      :disk_total_bytes,
      :disk_used_bytes,
      :disk_available_bytes,
      :disk_percent,
      :uptime_seconds
    ]
  end

  @sample_interval 200
  @max_proc_bytes 65_536
  @command_timeout :timer.seconds(10)

  @spec snapshot(keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def snapshot(opts \\ []) do
    read_file = Keyword.get(opts, :read_file, &File.read/1)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    execute = Keyword.get(opts, :execute, &Execution.run/2)

    with {:ok, cpu_before} <- read_cpu(read_file),
         :ok <- sleep.(@sample_interval),
         {:ok, cpu_after} <- read_cpu(read_file),
         {:ok, cpu_percent} <- cpu_percent(cpu_before, cpu_after),
         {:ok, memory} <- read_memory(read_file),
         {:ok, load} <- read_load(read_file),
         {:ok, uptime_seconds} <- read_uptime(read_file),
         {:ok, disk} <- read_disk(execute) do
      {:ok,
       struct!(
         Snapshot,
         %{
           hostname: hostname(),
           observed_at: DateTime.utc_now(),
           cpu_percent: cpu_percent,
           cpu_count: System.schedulers_online(),
           uptime_seconds: uptime_seconds
         }
         |> Map.merge(memory)
         |> Map.merge(load)
         |> Map.merge(disk)
       )}
    end
  end

  @doc false
  def cpu_percent({idle_before, total_before}, {idle_after, total_after}) do
    total_delta = total_after - total_before
    idle_delta = idle_after - idle_before

    if total_delta > 0 and idle_delta >= 0 do
      percent = (total_delta - idle_delta) / total_delta * 100
      {:ok, percent |> max(0.0) |> min(100.0) |> Float.round(1)}
    else
      {:error, :invalid_cpu_sample}
    end
  end

  @doc false
  def parse_cpu(content) do
    with [line | _rest] <- String.split(content, "\n", trim: true),
         ["cpu" | values] <- String.split(line, ~r/\s+/, trim: true),
         {:ok, counters} <- parse_integers(values),
         true <- length(counters) >= 4 do
      idle = Enum.at(counters, 3) + Enum.at(counters, 4, 0)
      {:ok, {idle, Enum.sum(counters)}}
    else
      _invalid -> {:error, :invalid_cpu_stat}
    end
  end

  @doc false
  def parse_memory(content) do
    values =
      content
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case Regex.run(~r/^([A-Za-z_()]+):\s+(\d+)\s+kB$/, line) do
          [_, name, value] -> Map.put(acc, name, String.to_integer(value) * 1024)
          _other -> acc
        end
      end)

    with total when is_integer(total) and total > 0 <- values["MemTotal"],
         available when is_integer(available) <- values["MemAvailable"] do
      used = max(total - available, 0)
      swap_total = values["SwapTotal"] || 0
      swap_free = values["SwapFree"] || 0

      {:ok,
       %{
         memory_total_bytes: total,
         memory_used_bytes: used,
         memory_percent: Float.round(used / total * 100, 1),
         swap_total_bytes: swap_total,
         swap_used_bytes: max(swap_total - swap_free, 0)
       }}
    else
      _invalid -> {:error, :invalid_memory_info}
    end
  end

  @doc false
  def parse_load(content) do
    with [one, five, fifteen, processes | _rest] <- String.split(content, ~r/\s+/, trim: true),
         {load_1, ""} <- Float.parse(one),
         {load_5, ""} <- Float.parse(five),
         {load_15, ""} <- Float.parse(fifteen),
         [running, total] <- String.split(processes, "/", parts: 2),
         {running_processes, ""} <- Integer.parse(running),
         {total_processes, ""} <- Integer.parse(total) do
      {:ok,
       %{
         load_1: load_1,
         load_5: load_5,
         load_15: load_15,
         running_processes: running_processes,
         total_processes: total_processes
       }}
    else
      _invalid -> {:error, :invalid_load_average}
    end
  end

  @doc false
  def parse_disk(content) do
    case content |> String.split("\n", trim: true) |> Enum.drop(1) do
      [line | _rest] ->
        with [total, used, available, percent, _mount] <- String.split(line, ~r/\s+/, trim: true),
             {total, ""} <- Integer.parse(total),
             {used, ""} <- Integer.parse(used),
             {available, ""} <- Integer.parse(available),
             {percent, "%"} <- Integer.parse(percent) do
          {:ok,
           %{
             disk_total_bytes: total,
             disk_used_bytes: used,
             disk_available_bytes: available,
             disk_percent: percent * 1.0
           }}
        else
          _invalid -> {:error, :invalid_disk_usage}
        end

      [] ->
        {:error, :invalid_disk_usage}
    end
  end

  defp read_cpu(read_file) do
    with {:ok, content} <- bounded_read(read_file, "/proc/stat"), do: parse_cpu(content)
  end

  defp read_memory(read_file) do
    with {:ok, content} <- bounded_read(read_file, "/proc/meminfo"), do: parse_memory(content)
  end

  defp read_load(read_file) do
    with {:ok, content} <- bounded_read(read_file, "/proc/loadavg"), do: parse_load(content)
  end

  defp read_uptime(read_file) do
    with {:ok, content} <- bounded_read(read_file, "/proc/uptime"),
         [uptime | _rest] <- String.split(content, ~r/\s+/, trim: true),
         {seconds, ""} <- Float.parse(uptime) do
      {:ok, trunc(seconds)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_uptime}
    end
  end

  defp read_disk(execute) do
    command = %Command{
      executable: Application.get_env(:nixploy, :df_executable, "df"),
      args: ["--block-size=1", "--output=size,used,avail,pcent,target", "--", "/"],
      timeout: @command_timeout,
      max_output_bytes: 8_192
    }

    case execute.(command, []) do
      {:ok, %{exit_status: 0, output_truncated?: false, output_tail: output}} ->
        parse_disk(output)

      {:ok, %{exit_status: 0, output_truncated?: true}} ->
        {:error, :disk_usage_too_large}

      {:ok, result} ->
        {:error, {:disk_usage_failed, result.exit_status}}

      {:error, reason} ->
        {:error, {:disk_usage_failed, reason}}
    end
  end

  defp bounded_read(read_file, path) do
    case read_file.(path) do
      {:ok, content} when byte_size(content) <= @max_proc_bytes -> {:ok, content}
      {:ok, _content} -> {:error, :machine_health_input_too_large}
      {:error, reason} -> {:error, {:machine_health_read_failed, path, reason}}
    end
  end

  defp parse_integers(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, parsed} ->
      case Integer.parse(value) do
        {integer, ""} -> {:cont, {:ok, [integer | parsed]}}
        _invalid -> {:halt, {:error, :invalid_integer}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      {:error, _reason} -> "unknown"
    end
  end
end
