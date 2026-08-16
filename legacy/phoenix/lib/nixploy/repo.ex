defmodule Nixploy.Repo do
  use Ecto.Repo,
    otp_app: :nixploy,
    adapter: Ecto.Adapters.Postgres
end
