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
