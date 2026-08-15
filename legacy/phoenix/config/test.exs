import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :bcrypt_elixir, log_rounds: 1

config :nixploy, Oban, testing: :manual
config :nixploy, :deployment_worker, Nixploy.Deployments.SimulatedWorker
config :nixploy, :simulated_deployment_step_ms, 0

config :nixploy, Nixploy.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "nixploy_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :nixploy, NixployWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "JvaJICWEX6qssEvpA7LegVq+PnJh6H0rcW7JJUg++robFXDnRyiy5yuPA5wGXoxr",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
