import Config

role =
  case System.get_env("NIXPLOY_ROLE", "all") |> String.trim() |> String.downcase() do
    "web" -> :web
    "worker" -> :worker
    "all" -> :all
    invalid -> raise "invalid NIXPLOY_ROLE #{inspect(invalid)}; expected web, worker, or all"
  end

web? = role in [:web, :all]
worker? = role in [:worker, :all]

config :nixploy, role: role

state_directory = System.get_env("STATE_DIRECTORY")

if is_binary(state_directory) do
  if web? do
    config :nixploy,
      release_registration_workspace_root: Path.join(state_directory, "release-registration")
  end

  if worker? do
    config :nixploy,
      preparation_workspace_root: Path.join(state_directory, "preparations"),
      operation_workspace_root: Path.join(state_directory, "operations"),
      release_gc_root_directory: Path.join(state_directory, "gcroots/releases")
  end
end

runtime_mode =
  System.get_env("NIXPLOY_RUNTIME_MODE", "local_recovery")
  |> Nixploy.RuntimeMode.parse!()

policy_mode =
  case System.get_env(
         "NIXPLOY_POLICY_MODE",
         if(runtime_mode == :remote_control_plane, do: "enforce", else: "shadow")
       ) do
    "shadow" -> :shadow
    "enforce" -> :enforce
    invalid -> raise "invalid NIXPLOY_POLICY_MODE #{inspect(invalid)}; expected shadow or enforce"
  end

config :nixploy,
  runtime_mode: runtime_mode,
  deployment_policy_mode: policy_mode,
  deployment_policy_component: System.get_env("NIXPLOY_POLICY_COMPONENT"),
  wasmtime_executable: System.get_env("NIXPLOY_WASMTIME_EXECUTABLE"),
  native_deployment_executor:
    if(runtime_mode == :remote_control_plane,
      do: Nixploy.Deployments.RemoteCliExecutor,
      else: Nixploy.Deployments.NativeExecutor
    )

managed_applications =
  System.get_env("NIXPLOY_MANAGED_APPLICATIONS_JSON", "{}")
  |> Jason.decode!()
  |> Map.new(fn {key, application} ->
    normalized = %{
      "project" => Map.fetch!(application, "project"),
      "target" => Map.fetch!(application, "target"),
      "repository" => Map.fetch!(application, "repository"),
      "repository_identity" => Map.fetch!(application, "repositoryIdentity"),
      "subdirectory" => Map.get(application, "subdirectory", ".")
    }

    {key, normalized}
  end)

managed_application_credentials =
  if worker? do
    System.get_env("NIXPLOY_MANAGED_APPLICATION_CREDENTIALS_JSON", "{}")
    |> Jason.decode!()
  else
    %{}
  end

managed_applications =
  Map.new(managed_applications, fn {key, application} ->
    credential_path = Map.get(managed_application_credentials, key)

    {key,
     if(is_binary(credential_path),
       do: Map.put(application, "credential_path", credential_path),
       else: application
     )}
  end)

config :nixploy, managed_applications: managed_applications

auth_mode =
  case System.get_env(
         "NIXPLOY_AUTH_MODE",
         if(config_env() == :prod, do: "tailscale", else: "password")
       )
       |> String.trim()
       |> String.downcase() do
    "password" ->
      :password

    "tailscale" ->
      :tailscale

    invalid ->
      raise "invalid NIXPLOY_AUTH_MODE #{inspect(invalid)}; expected password or tailscale"
  end

config :nixploy, auth_mode: auth_mode

release_registration_token_file = System.get_env("NIXPLOY_RELEASE_REGISTRATION_TOKEN_FILE")

if web? and is_binary(release_registration_token_file) do
  config :nixploy, :release_registration,
    token_file: release_registration_token_file,
    operator_email: System.fetch_env!("NIXPLOY_OPERATOR_EMAIL"),
    project: System.fetch_env!("NIXPLOY_RELEASE_REGISTRATION_PROJECT"),
    target: System.get_env("NIXPLOY_RELEASE_REGISTRATION_TARGET", "production"),
    repository: System.fetch_env!("NIXPLOY_RELEASE_REGISTRATION_REPOSITORY")
end

if executable = System.get_env("NIXPLOY_LEGACY_EXECUTABLE") do
  config :nixploy, :legacy_nixploy_executable, executable
end

if executable = System.get_env("NIXPLOY_REMOTE_CLI_EXECUTABLE") do
  config :nixploy, :remote_cli_executable, executable
end

unless config_env() == :test do
  # Keep the MVP queue deliberately narrow in addition to PostgreSQL target
  # leases; increasing concurrency is safe only after production load testing.
  config :nixploy, Oban,
    queues: if(worker?, do: [deployments: 1, health_checks: 2, logs: 2], else: false),
    plugins: if(worker?, do: [Oban.Plugins.Pruner], else: false)
end

config :nixploy, NixployWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :nixploy, Nixploy.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    socket_options: maybe_ipv6

  if web? do
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing for the web role.
        Generate one with: mix phx.gen.secret
        """

    host = System.get_env("PHX_HOST", "localhost")

    bind_ip =
      System.get_env("PHX_BIND_IP", "127.0.0.1")
      |> String.to_charlist()
      |> :inet.parse_address()
      |> case do
        {:ok, address} -> address
        {:error, reason} -> raise "invalid PHX_BIND_IP: #{inspect(reason)}"
      end

    config :nixploy, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

    config :nixploy, NixployWeb.Endpoint,
      server: true,
      url: [host: host, port: 443, scheme: "https"],
      http: [ip: bind_ip],
      secret_key_base: secret_key_base
  else
    config :nixploy, NixployWeb.Endpoint, server: false
  end
end
