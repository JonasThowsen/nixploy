defmodule Nixploy.Deployments.OutputBuffer do
  @moduledoc false

  alias Nixploy.Deployments

  @flush_bytes 16_384

  def start(deployment_id) do
    with {:ok, _output} <- Deployments.reset_output(deployment_id) do
      Process.put(key(deployment_id), {[], 0, 0})
      Process.delete(error_key(deployment_id))
      :ok
    end
  end

  def append(deployment_id, line) when is_binary(line) do
    entry = line <> "\n"
    {entries, bytes, lines} = Process.get(key(deployment_id), {[], 0, 0})
    state = {[entry | entries], bytes + byte_size(entry), lines + 1}
    Process.put(key(deployment_id), state)

    if elem(state, 1) >= @flush_bytes, do: flush(deployment_id), else: :ok
  end

  def finish(deployment_id) do
    result = flush(deployment_id)
    Process.delete(key(deployment_id))

    case Process.delete(error_key(deployment_id)) do
      nil -> result
      reason -> {:error, {:deployment_output_failed, reason}}
    end
  end

  def failed?(deployment_id), do: not is_nil(Process.get(error_key(deployment_id)))

  defp flush(deployment_id) do
    case Process.get(key(deployment_id), {[], 0, 0}) do
      {[], 0, 0} ->
        :ok

      {entries, _bytes, lines} ->
        content = entries |> Enum.reverse() |> IO.iodata_to_binary()

        case Deployments.append_output(deployment_id, content, lines) do
          {:ok, _output} ->
            Process.put(key(deployment_id), {[], 0, 0})
            :ok

          {:error, reason} ->
            Process.put(error_key(deployment_id), reason)
            {:error, reason}
        end
    end
  end

  defp key(deployment_id), do: {__MODULE__, deployment_id}
  defp error_key(deployment_id), do: {__MODULE__, deployment_id, :error}
end
