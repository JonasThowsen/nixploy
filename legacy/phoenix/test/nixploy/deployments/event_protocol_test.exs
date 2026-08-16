defmodule Nixploy.Deployments.EventProtocolTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.EventProtocol

  @operation "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

  test "accepts ordered stages and exactly one matching terminal event" do
    assert {:event, preparing, state} =
             EventProtocol.consume(
               event(1, "stage", "preparing", nil, nil),
               EventProtocol.initial(),
               @operation
             )

    assert preparing.stage == :preparing

    assert {:event, terminal, terminal_state} =
             EventProtocol.consume(
               event(2, "terminal", "succeeded", "succeeded", "ok"),
               state,
               @operation
             )

    assert terminal.type == :terminal
    assert terminal_state.terminal?

    assert {:error, :event_after_terminal} =
             EventProtocol.consume(
               event(3, "stage", "verifying", nil, nil),
               terminal_state,
               @operation
             )
  end

  test "fails closed on sequence gaps, operation mismatches, unknown artifacts, and oversized lines" do
    assert {:error, :invalid_event_sequence} =
             EventProtocol.consume(
               event(2, "stage", "preparing", nil, nil),
               EventProtocol.initial(),
               @operation
             )

    assert {:error, :event_operation_mismatch} =
             EventProtocol.consume(
               event(1, "stage", "preparing", nil, nil, "other"),
               EventProtocol.initial(),
               @operation
             )

    assert {:error, :unknown_event_artifact} =
             EventProtocol.consume(
               event(1, "stage", "preparing", nil, nil, @operation, %{"secret" => "not allowed"}),
               EventProtocol.initial(),
               @operation
             )

    assert {:error, :event_line_too_large} =
             EventProtocol.consume(
               String.duplicate("x", 65_537),
               EventProtocol.initial(),
               @operation
             )
  end

  test "treats non-protocol output as diagnostics without advancing sequence" do
    state = EventProtocol.initial()

    assert {:diagnostic, "human diagnostic", ^state} =
             EventProtocol.consume("human diagnostic", state, @operation)
  end

  defp event(sequence, type, stage, status, code, operation \\ @operation, artifacts \\ %{}) do
    Jason.encode!(%{
      "schema" => "nixploy.event/v1",
      "seq" => sequence,
      "type" => type,
      "stage" => stage,
      "code" => code,
      "message" => "bounded message",
      "operation_id" => operation,
      "status" => status,
      "artifacts" => artifacts
    })
  end
end
