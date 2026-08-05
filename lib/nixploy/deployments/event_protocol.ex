defmodule Nixploy.Deployments.EventProtocol do
  @moduledoc "Strict parser for bounded packaged-CLI deployment events."

  @schema "nixploy.event/v1"
  @max_line_bytes 65_536
  @stages ~w(preparing building loading installing_credentials preparing_slot pre_starting starting health_checking switching verifying succeeded failed)a
  @artifact_keys ~w(resource_key image_reference image_id selected_slot selected_port previous_upstream verified_upstream container_name container_id)a

  @type state :: %{sequence: non_neg_integer(), terminal?: boolean()}

  def initial, do: %{sequence: 0, terminal?: false}

  def consume(line, state, operation_id) when is_binary(line) do
    cond do
      byte_size(line) > @max_line_bytes ->
        {:error, :event_line_too_large}

      state.terminal? ->
        {:error, :event_after_terminal}

      true ->
        decode(line, state, operation_id)
    end
  end

  defp decode(line, state, operation_id) do
    case Jason.decode(line) do
      {:ok, %{"schema" => @schema} = event} -> validate(event, state, operation_id)
      {:ok, %{"schema" => _other}} -> {:error, :unsupported_event_schema}
      _diagnostic -> {:diagnostic, line, state}
    end
  end

  defp validate(event, state, operation_id) do
    with :ok <- exact_sequence(event, state.sequence + 1),
         :ok <- exact_operation(event, operation_id),
         {:ok, stage} <- stage(event),
         {:ok, type, terminal?} <- type(event, stage),
         {:ok, message} <- required_string(event, "message"),
         {:ok, artifacts} <- artifacts(event),
         {:ok, code} <- code(event, type) do
      next_state = %{sequence: state.sequence + 1, terminal?: terminal?}

      {:event, %{type: type, stage: stage, message: message, code: code, attrs: artifacts},
       next_state}
    end
  end

  defp exact_sequence(%{"seq" => expected}, expected), do: :ok
  defp exact_sequence(_event, _expected), do: {:error, :invalid_event_sequence}

  defp exact_operation(%{"operation_id" => expected}, expected), do: :ok
  defp exact_operation(_event, _expected), do: {:error, :event_operation_mismatch}

  defp stage(%{"stage" => stage}) when is_binary(stage) do
    case Enum.find(@stages, &(Atom.to_string(&1) == stage)) do
      nil -> {:error, :unknown_event_stage}
      stage -> {:ok, stage}
    end
  end

  defp stage(_event), do: {:error, :invalid_event_stage}

  defp type(%{"type" => "stage", "status" => nil}, stage)
       when stage not in [:succeeded, :failed],
       do: {:ok, :stage, false}

  defp type(%{"type" => "terminal", "status" => "succeeded"}, :succeeded),
    do: {:ok, :terminal, true}

  defp type(%{"type" => "terminal", "status" => "failed"}, :failed),
    do: {:ok, :terminal, true}

  defp type(_event, _stage), do: {:error, :invalid_event_type}

  defp required_string(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and byte_size(value) in 1..4_096 -> {:ok, value}
      _invalid -> {:error, :invalid_event_message}
    end
  end

  defp artifacts(%{"artifacts" => artifacts})
       when is_map(artifacts) and map_size(artifacts) <= 16 do
    Enum.reduce_while(artifacts, {:ok, %{}}, fn {key, value}, {:ok, attrs} ->
      case Enum.find(@artifact_keys, &(Atom.to_string(&1) == key)) do
        nil ->
          {:halt, {:error, :unknown_event_artifact}}

        atom when is_binary(value) or is_integer(value) or is_nil(value) ->
          {:cont, {:ok, Map.put(attrs, atom, value)}}

        _atom ->
          {:halt, {:error, :invalid_event_artifact}}
      end
    end)
  end

  defp artifacts(_event), do: {:error, :invalid_event_artifacts}

  defp code(%{"code" => nil}, :stage), do: {:ok, nil}

  defp code(%{"code" => code}, :terminal) when is_binary(code) and byte_size(code) in 1..128,
    do: {:ok, code}

  defp code(_event, _type), do: {:error, :invalid_event_code}
end
