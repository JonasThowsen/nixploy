defmodule Nixploy.MachineHealthTest do
  use ExUnit.Case, async: true

  alias Nixploy.Execution.Result
  alias Nixploy.MachineHealth

  test "collects a bounded point-in-time local machine snapshot" do
    parent = self()

    read_file = fn
      "/proc/stat" ->
        sample = Process.get(:cpu_sample, 0)
        Process.put(:cpu_sample, sample + 1)

        if sample == 0,
          do: {:ok, "cpu  100 0 50 850 0 0 0 0\ncpu0 50 0 25 425\n"},
          else: {:ok, "cpu  120 0 60 920 0 0 0 0\ncpu0 60 0 30 460\n"}

      "/proc/meminfo" ->
        {:ok,
         "MemTotal:        8000000 kB\nMemAvailable:   3000000 kB\nSwapTotal:      1000000 kB\nSwapFree:        750000 kB\n"}

      "/proc/loadavg" ->
        {:ok, "0.25 0.50 0.75 2/321 12345\n"}

      "/proc/uptime" ->
        {:ok, "93784.42 1234.00\n"}
    end

    execute = fn command, [] ->
      send(parent, {:command, command})

      {:ok,
       %Result{
         exit_status: 0,
         output_tail:
           "       1B-blocks           Used      Available Use% Mounted on\n      100000000000    61000000000    39000000000  61% /\n"
       }}
    end

    assert {:ok, snapshot} =
             MachineHealth.snapshot(
               read_file: read_file,
               sleep: fn 200 -> :ok end,
               execute: execute
             )

    assert snapshot.cpu_percent == 30.0
    assert snapshot.memory_total_bytes == 8_192_000_000
    assert snapshot.memory_used_bytes == 5_120_000_000
    assert snapshot.memory_percent == 62.5
    assert snapshot.swap_used_bytes == 256_000_000
    assert snapshot.load_1 == 0.25
    assert snapshot.load_5 == 0.5
    assert snapshot.load_15 == 0.75
    assert snapshot.running_processes == 2
    assert snapshot.total_processes == 321
    assert snapshot.uptime_seconds == 93_784
    assert snapshot.disk_total_bytes == 100_000_000_000
    assert snapshot.disk_used_bytes == 61_000_000_000
    assert snapshot.disk_available_bytes == 39_000_000_000
    assert snapshot.disk_percent == 61.0
    assert %DateTime{} = snapshot.observed_at

    assert_receive {:command, command}
    assert command.executable == "df"

    assert command.args == [
             "--block-size=1",
             "--output=size,used,avail,pcent,target",
             "--",
             "/"
           ]

    assert command.timeout == 10_000
    assert command.max_output_bytes == 8_192
  end

  test "rejects malformed and oversized machine inputs" do
    assert {:error, :invalid_cpu_stat} = MachineHealth.parse_cpu("not cpu data")
    assert {:error, :invalid_memory_info} = MachineHealth.parse_memory("MemFree: 10 kB")
    assert {:error, :invalid_load_average} = MachineHealth.parse_load("invalid")
    assert {:error, :invalid_disk_usage} = MachineHealth.parse_disk("header only")

    assert {:error, :machine_health_input_too_large} =
             MachineHealth.snapshot(
               read_file: fn _path -> {:ok, String.duplicate("x", 65_537)} end,
               sleep: fn _milliseconds -> :ok end,
               execute: fn _command, _opts -> flunk() end
             )
  end
end
