defmodule NixployWeb.ReleaseRegistrationAuth do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Nixploy.ReleaseRegistration

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, operator, config} <- ReleaseRegistration.authenticate(token) do
      conn
      |> assign(:release_registration_operator, operator)
      |> assign(:release_registration_config, config)
    else
      _error ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "release registration denied"}})
        |> halt()
    end
  end
end
