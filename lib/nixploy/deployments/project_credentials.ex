defmodule Nixploy.Deployments.ProjectCredentials do
  @moduledoc "Resolves encrypted project credential references inside a worker-only process."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command
  alias Nixploy.RuntimeRole

  @decrypt_timeout :timer.minutes(1)
  @max_decrypted_bytes 262_144
  @max_secrets 128
  @max_secret_value_bytes 16_384
  @secret_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @credential_name "nixploy-sops-age-ssh-key"

  @type secret :: %{name: String.t(), value: String.t()}

  @spec resolve(map(), keyword()) :: {:ok, [secret()]} | {:error, term()}
  def resolve(references, opts \\ [])

  def resolve(references, opts) when is_map(references) do
    execute = Keyword.get(opts, :execute, &Execution.run/2)
    worker? = Keyword.get(opts, :worker?, fn -> RuntimeRole.current() == :worker end)
    execution_opts = Keyword.take(opts, [:cancelled?])

    with true <- worker?.() || {:error, :credential_worker_required},
         {:ok, identity_file} <- identity_file(opts),
         {:ok, secrets} <- decrypt_all(references, identity_file, execute, execution_opts) do
      {:ok, secrets |> Map.values() |> Enum.sort_by(& &1.name)}
    end
  end

  def resolve(_references, _opts), do: {:error, :credential_references_invalid}

  @doc false
  def parse_dotenv(content)
      when is_binary(content) and byte_size(content) <= @max_decrypted_bytes do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {raw_line, line_number}, {:ok, secrets} ->
      case parse_line(raw_line) do
        :skip ->
          {:cont, {:ok, secrets}}

        {:ok, name, value} when map_size(secrets) < @max_secrets ->
          if Map.has_key?(secrets, name) do
            {:halt, {:error, {:duplicate_credential, name}}}
          else
            {:cont, {:ok, Map.put(secrets, name, %{name: name, value: value})}}
          end

        {:ok, _name, _value} ->
          {:halt, {:error, :too_many_credentials}}

        {:error, _reason} ->
          {:halt, {:error, {:invalid_dotenv_line, line_number}}}
      end
    end)
    |> case do
      {:ok, secrets} when map_size(secrets) > 0 ->
        {:ok, secrets |> Map.values() |> Enum.sort_by(& &1.name)}

      {:ok, _empty} ->
        {:error, :credential_file_empty}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse_dotenv(_content), do: {:error, :credential_file_too_large}

  defp decrypt_all(references, identity_file, execute, execution_opts) do
    references
    |> Enum.sort_by(fn {label, _reference} -> label end)
    |> Enum.reduce_while({:ok, %{}}, fn {label, reference}, {:ok, secrets} ->
      with {:ok, decrypted} <-
             decrypt(label, reference, identity_file, execute, execution_opts),
           {:ok, file_secrets} <- parse_dotenv(decrypted),
           {:ok, merged} <- merge_unique(secrets, file_secrets) do
        {:cont, {:ok, merged}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decrypt(label, reference, identity_file, execute, execution_opts) do
    command = %Command{
      executable: sops(),
      args: [
        "decrypt",
        "--input-type",
        "dotenv",
        "--output-type",
        "dotenv",
        "--",
        reference
      ],
      env: %{"SOPS_AGE_SSH_PRIVATE_KEY_FILE" => identity_file},
      timeout: @decrypt_timeout,
      max_output_bytes: @max_decrypted_bytes
    }

    case execute.(command, execution_opts) do
      {:ok, %{exit_status: 0, output_truncated?: false, output_tail: output}} ->
        {:ok, output}

      _failure ->
        {:error, {:credential_decryption_failed, label}}
    end
  end

  defp merge_unique(existing, incoming) do
    Enum.reduce_while(incoming, {:ok, existing}, fn %{name: name} = secret, {:ok, merged} ->
      if Map.has_key?(merged, name) do
        {:halt, {:error, {:duplicate_credential, name}}}
      else
        {:cont, {:ok, Map.put(merged, name, secret)}}
      end
    end)
  end

  defp parse_line(raw_line) do
    line = raw_line |> String.trim_trailing("\r") |> String.trim()

    cond do
      line == "" or String.starts_with?(line, "#") ->
        :skip

      true ->
        line
        |> String.replace_prefix("export ", "")
        |> split_assignment()
    end
  end

  defp split_assignment(line) do
    case :binary.match(line, "=") do
      {index, 1} when index > 0 ->
        name = line |> binary_part(0, index) |> String.trim()
        raw_value = binary_part(line, index + 1, byte_size(line) - index - 1) |> String.trim()

        with true <- Regex.match?(@secret_name, name),
             {:ok, value} <- parse_value(raw_value),
             true <- value != "" and byte_size(value) <= @max_secret_value_bytes,
             false <- String.contains?(value, <<0>>) do
          {:ok, name, value}
        else
          _invalid -> {:error, :invalid_assignment}
        end

      _missing ->
        {:error, :assignment_missing}
    end
  end

  defp parse_value(<<"\"", rest::binary>>) do
    with true <- String.ends_with?(rest, "\""),
         quoted <- binary_part(rest, 0, byte_size(rest) - 1),
         {:ok, value} <- unescape_double_quoted(quoted) do
      {:ok, value}
    else
      _invalid -> {:error, :invalid_quoted_value}
    end
  end

  defp parse_value(<<"'", rest::binary>>) do
    if String.ends_with?(rest, "'") do
      {:ok, binary_part(rest, 0, byte_size(rest) - 1)}
    else
      {:error, :invalid_quoted_value}
    end
  end

  defp parse_value(value) do
    value =
      case :binary.match(value, " #") do
        {index, 2} -> value |> binary_part(0, index) |> String.trim_trailing()
        :nomatch -> value
      end

    {:ok, value}
  end

  defp unescape_double_quoted(value), do: unescape_double_quoted(value, [])
  defp unescape_double_quoted("", acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp unescape_double_quoted(<<"\\", escaped, rest::binary>>, acc) do
    value =
      case escaped do
        ?n -> "\n"
        ?r -> "\r"
        ?t -> "\t"
        ?\\ -> "\\"
        ?\" -> "\""
        other -> <<other>>
      end

    unescape_double_quoted(rest, [value | acc])
  end

  defp unescape_double_quoted(<<"\\">>, _acc), do: {:error, :invalid_escape}

  defp unescape_double_quoted(<<codepoint::utf8, rest::binary>>, acc),
    do: unescape_double_quoted(rest, [<<codepoint::utf8>> | acc])

  defp identity_file(opts) do
    path_exists? = Keyword.get(opts, :path_exists?, &File.regular?/1)

    case Keyword.get(opts, :identity_file) || systemd_identity_file() do
      path when is_binary(path) and path != "" ->
        if path_exists?.(path),
          do: {:ok, path},
          else: {:error, :credential_identity_unavailable}

      _missing ->
        {:error, :credential_identity_unavailable}
    end
  end

  defp systemd_identity_file do
    case System.get_env("CREDENTIALS_DIRECTORY") do
      directory when is_binary(directory) and directory != "" ->
        Path.join(directory, @credential_name)

      _missing ->
        nil
    end
  end

  defp sops, do: Application.get_env(:nixploy, :sops_executable, "sops")
end
