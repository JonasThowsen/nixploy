defmodule Nixploy.RuntimeMode do
  @moduledoc "Identifies whether this host is the remote control plane or an explicit local recovery runtime."

  @type t :: :remote_control_plane | :local_recovery

  @spec current() :: t()
  def current, do: Application.get_env(:nixploy, :runtime_mode, :local_recovery)

  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "remote_control_plane" -> {:ok, :remote_control_plane}
      "local_recovery" -> {:ok, :local_recovery}
      _invalid -> {:error, "expected one of: remote_control_plane, local_recovery"}
    end
  end

  @spec parse!(String.t()) :: t()
  def parse!(value) do
    case parse(value) do
      {:ok, mode} -> mode
      {:error, message} -> raise ArgumentError, "invalid NIXPLOY_RUNTIME_MODE: #{message}"
    end
  end

  def remote_control_plane?(:remote_control_plane), do: true
  def remote_control_plane?(_mode), do: false
end
