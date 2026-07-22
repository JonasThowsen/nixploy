defmodule NixployWeb.OperatorSessionController do
  use NixployWeb, :controller

  alias Nixploy.Accounts
  alias NixployWeb.OperatorAuth

  def new(conn, _params) do
    form = Phoenix.Component.to_form(%{"email" => ""}, as: :operator)
    render(conn, :new, form: form)
  end

  # TODO(tracer): Add per-origin and per-identity login throttling before the
  # control plane is exposed beyond a trusted operator network.
  def create(conn, %{"operator" => %{"email" => email, "password" => password}}) do
    case Accounts.authenticate_operator(email, password) do
      {:ok, operator} ->
        {conn, return_to} = OperatorAuth.log_in_operator(conn, operator)

        conn
        |> put_flash(:info, "Signed in")
        |> redirect(to: return_to)

      {:error, :invalid_credentials} ->
        form = Phoenix.Component.to_form(%{"email" => email}, as: :operator)

        conn
        |> put_flash(:error, "Invalid email or password")
        |> put_status(:unprocessable_entity)
        |> render(:new, form: form)
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid email or password")
    |> put_status(:unprocessable_entity)
    |> render(:new, form: Phoenix.Component.to_form(%{"email" => ""}, as: :operator))
  end

  def delete(conn, _params) do
    conn
    |> OperatorAuth.log_out_operator()
    |> put_flash(:info, "Signed out")
    |> redirect(to: ~p"/login")
  end
end
