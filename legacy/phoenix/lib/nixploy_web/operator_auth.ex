defmodule NixployWeb.OperatorAuth do
  @moduledoc "HTTP and LiveView authentication for provisioned operators."

  import Phoenix.Controller
  import Plug.Conn

  use NixployWeb, :verified_routes

  alias Nixploy.{Accounts, Audit}

  @session_key :operator_id
  @tailscale_login_header "tailscale-user-login"

  def auth_mode, do: Application.fetch_env!(:nixploy, :auth_mode)
  def password_auth?, do: auth_mode() == :password
  def tailscale_auth?, do: auth_mode() == :tailscale

  def fetch_current_operator(conn, _opts) do
    case auth_mode() do
      :password -> fetch_session_operator(conn)
      :tailscale -> fetch_tailscale_operator(conn)
    end
  end

  def require_authenticated_operator(%{assigns: %{current_operator: nil}} = conn, _opts) do
    if tailscale_auth?() do
      conn
      |> send_resp(:forbidden, "Tailscale identity is not authorized for nixploy")
      |> halt()
    else
      conn
      |> maybe_store_return_to()
      |> put_flash(:error, "Sign in to access the control plane")
      |> redirect(to: ~p"/login")
      |> halt()
    end
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

  defp fetch_session_operator(conn) do
    operator = conn |> get_session(@session_key) |> Accounts.get_operator()
    assign(conn, :current_operator, operator)
  end

  defp fetch_tailscale_operator(conn) do
    with {:ok, login} <- tailscale_login(conn),
         operator when not is_nil(operator) <- Accounts.get_operator_by_email(login) do
      establish_tailscale_session(conn, operator, login)
    else
      _reason ->
        conn
        |> delete_session(@session_key)
        |> assign(:current_operator, nil)
    end
  end

  defp establish_tailscale_session(conn, operator, login) do
    if get_session(conn, @session_key) == operator.id do
      assign(conn, :current_operator, operator)
    else
      case Audit.record(operator, :login, :session, request_id(conn),
             metadata: %{"authentication" => "tailscale", "tailscale_user_login" => login}
           ) do
        {:ok, _event} ->
          conn
          |> configure_session(renew: true)
          |> clear_session()
          |> put_session(@session_key, operator.id)
          |> assign(:current_operator, operator)

        {:error, _reason} ->
          assign(conn, :current_operator, nil)
      end
    end
  end

  defp tailscale_login(conn) do
    case get_req_header(conn, @tailscale_login_header) do
      [login] -> normalize_login(login)
      _missing_or_ambiguous -> :error
    end
  end

  defp normalize_login(login) do
    case login |> String.trim() |> String.downcase() do
      "" -> :error
      normalized -> {:ok, normalized}
    end
  end

  defp request_id(conn), do: List.first(get_resp_header(conn, "x-request-id")) || "unknown"

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :operator_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
