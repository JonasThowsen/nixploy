mix_env = Mix.env()

credentials =
  case {
    System.get_env("NIXPLOY_OPERATOR_EMAIL"),
    System.get_env("NIXPLOY_OPERATOR_PASSWORD")
  } do
    {email, password} when is_binary(email) and is_binary(password) ->
      {email, password}

    {nil, nil} when mix_env == :dev ->
      secrets_file = Path.expand("secrets/dev.env")

      sops =
        System.find_executable("sops") ||
          raise "sops is required to seed the development operator from #{secrets_file}"

      decrypt = fn key ->
        case System.cmd(
               sops,
               ["decrypt", "--extract", ~s(["#{key}"]), secrets_file],
               stderr_to_stdout: true
             ) do
          {value, 0} ->
            String.trim_trailing(value, "\n")

          {output, status} ->
            raise "could not decrypt #{key} with sops (exit #{status}): #{output}"
        end
      end

      {decrypt.("NIXPLOY_OPERATOR_EMAIL"), decrypt.("NIXPLOY_OPERATOR_PASSWORD")}

    {nil, nil} ->
      nil

    _partial ->
      raise "NIXPLOY_OPERATOR_EMAIL and NIXPLOY_OPERATOR_PASSWORD must be set together"
  end

case credentials do
  {email, password} ->
    case Nixploy.Accounts.provision_operator(%{email: email, password: password}) do
      {:ok, operator} ->
        IO.puts("Seeded operator #{operator.email}")

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
            Enum.reduce(opts, message, fn {key, value}, rendered ->
              String.replace(rendered, "%{#{key}}", to_string(value))
            end)
          end)

        raise "could not seed operator: #{inspect(errors)}"
    end

  nil ->
    :ok
end
