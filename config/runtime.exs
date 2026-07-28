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

if executable = System.get_env("NIXPLOY_LEGACY_EXECUTABLE") do
  config :nixploy, :legacy_nixploy_executable, executable
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
