defmodule NixployWeb.HealthController do
  use NixployWeb, :controller

  alias Nixploy.Repo

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    case Repo.query("SELECT 1") do
      {:ok, _result} ->
        json(conn, %{status: "ready"})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable"})
    end
  end
end
