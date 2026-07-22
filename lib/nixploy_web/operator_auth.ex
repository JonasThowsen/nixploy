defmodule NixployWeb.OperatorAuth do
  @moduledoc "HTTP and LiveView session authentication for provisioned operators."

  import Phoenix.Controller
  import Plug.Conn

  use NixployWeb, :verified_routes

  alias Nixploy.Accounts

  # TODO(tracer): Replace the short-lived operator-id cookie with revocable,
  # server-side session tokens before adding multi-device session management.
  @session_key :operator_id

  def fetch_current_operator(conn, _opts) do
    operator = conn |> get_session(@session_key) |> Accounts.get_operator()
    assign(conn, :current_operator, operator)
  end

  def require_authenticated_operator(%{assigns: %{current_operator: nil}} = conn, _opts) do
    conn
    |> maybe_store_return_to()
    |> put_flash(:error, "Sign in to access the control plane")
    |> redirect(to: ~p"/login")
    |> halt()
  end

  def require_authenticated_operator(conn, _opts), do: conn

  def log_in_operator(conn, operator) do
    return_to = get_session(conn, :operator_return_to) || ~p"/"

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@session_key, operator.id)
    |> then(&{&1, return_to})
  end

  def log_out_operator(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    case session |> Map.get(to_string(@session_key)) |> Accounts.get_operator() do
      nil ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Sign in to access the control plane")
         |> Phoenix.LiveView.redirect(to: ~p"/login")}

      operator ->
        {:cont, Phoenix.Component.assign(socket, :current_operator, operator)}
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :operator_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
