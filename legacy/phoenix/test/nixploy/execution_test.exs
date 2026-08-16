defmodule Nixploy.ExecutionTest do
  use ExUnit.Case, async: true

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  test "passes arguments directly and streams output lines" do
    lines = self()

    command = %Command{
      executable: "printf",
      args: ["first=%s\\nsecond=%s\\n", "hello world", "; touch /tmp/not-executed"]
    }

    assert {:ok, result} =
             Execution.run(command,
               on_line: fn line -> send(lines, {:line, line}) end
             )

    assert result.exit_status == 0
    assert result.output_tail =~ "; touch /tmp/not-executed"
    assert_receive {:line, "first=hello world"}
    assert_receive {:line, "second=; touch /tmp/not-executed"}
  end

  test "writes bounded command input through stdin without putting it in argv or environment" do
    secret = "worker-only-secret-value"

    command = %Command{
      executable: "cat",
      stdin: secret,
      redact: [secret]
    }

    assert {:ok, result} = Execution.run(command)
    assert result.exit_status == 0
    assert result.output_tail == "[REDACTED]"
    assert command.args == []
    assert command.env == %{}
  end

  test "redacts configured values from streamed and retained output" do
    command = %Command{
      executable: "printf",
      args: ["token=secret-value\\n"],
      redact: ["secret-value"]
    }

    assert {:ok, result} =
             Execution.run(command,
               on_line: fn line -> send(self(), {:redacted_line, line}) end
             )

    assert result.output_tail == "token=[REDACTED]\n"
    assert_receive {:redacted_line, "token=[REDACTED]"}
  end

  test "bounds retained output and reports truncation" do
    command = %Command{
      executable: "printf",
      args: ["0123456789abcdef"],
      max_output_bytes: 10
    }

    assert {:ok, result} = Execution.run(command)
    assert result.output_tail == "6789abcdef"
    assert result.output_truncated?
  end

  test "bounds streamed chunks even when output contains no newlines" do
    parent = self()
    payload = String.duplicate("x", 12_000)
    command = %Command{executable: "printf", args: ["%s", payload], max_output_bytes: 16_000}

    assert {:ok, result} =
             Execution.run(command, on_line: &send(parent, {:chunk, byte_size(&1)}))

    assert result.exit_status == 0
    assert_receive {:chunk, 4_096}
    assert_receive {:chunk, 4_096}
    assert_receive {:chunk, 3_808}
    refute_receive {:chunk, _size}
  end

  test "continuous output cannot starve cancellation checks" do
    started_at = System.monotonic_time(:millisecond)

    command = %Command{
      executable: "sh",
      args: ["-c", "while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done"],
      timeout: :timer.seconds(5),
      max_output_bytes: 1_024
    }

    assert {:error, :cancelled} =
             Execution.run(command,
               cancelled?: fn ->
                 System.monotonic_time(:millisecond) - started_at > 100
               end
             )

    assert System.monotonic_time(:millisecond) - started_at < 2_000
  end

  test "cancellation terminates the external process group" do
    marker =
      Path.join(System.tmp_dir!(), "nixploy-cancelled-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(marker) end)
    started_at = System.monotonic_time(:millisecond)

    command = %Command{
      executable: "sh",
      args: ["-c", "sleep 2; touch #{marker}"],
      timeout: :timer.seconds(5)
    }

    assert {:error, :cancelled} =
             Execution.run(command,
               cancelled?: fn ->
                 System.monotonic_time(:millisecond) - started_at > 100
               end
             )

    Process.sleep(300)
    refute File.exists?(marker)
  end

  test "reports a missing executable" do
    command = %Command{executable: "nixploy-command-that-does-not-exist"}

    assert {:error, {:executable_not_found, _executable}} = Execution.run(command)
  end
end
