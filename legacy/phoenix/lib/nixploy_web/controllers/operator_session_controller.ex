defmodule NixployWeb.OperatorSessionController do
  use NixployWeb, :controller

  alias Nixploy.{Accounts, Audit}
  alias NixployWeb.OperatorAuth

  def new(%{assigns: %{current_operator: operator}} = conn, _params) when not is_nil(operator) do
    redirect(conn, to: ~p"/")
  end

  def new(conn, _params) do
    if OperatorAuth.tailscale_auth?() do
      send_resp(conn, :forbidden, "Access nixploy through an authorized Tailscale identity")
    else
      form = Phoenix.Component.to_form(%{"email" => ""}, as: :operator)
      render(conn, :new, form: form)
    end
  end

  def create(conn, params) do
    if OperatorAuth.tailscale_auth?() do
      send_resp(
        conn,
        :forbidden,
        "Password login is disabled when Tailscale authentication is enabled"
      )
    else
      create_password_session(conn, params)
    end
  end

  def delete(conn, _params) do
    _ = Audit.record(conn.assigns.current_operator, :logout, :session, request_id(conn))

    conn
    |> OperatorAuth.log_out_operator()
    |> put_flash(:info, "Signed out")
    |> redirect(to: if(OperatorAuth.tailscale_auth?(), do: ~p"/", else: ~p"/login"))
  end

  defp create_password_session(
         conn,
         %{"operator" => %{"email" => email, "password" => password}}
       ) do
    fingerprint = email_fingerprint(email)
    origin = remote_origin(conn)

    authentication =
      if Audit.login_allowed?(fingerprint, origin),
        do: Accounts.authenticate_operator(email, password),
        else: {:error, :invalid_credentials}

    case authentication do
      {:ok, operator} ->
        case Audit.record(operator, :login, :session, request_id(conn),
               metadata: %{"authentication" => "password"}
             ) do
          {:ok, _event} ->
            {conn, return_to} = OperatorAuth.log_in_operator(conn, operator)

            conn
            |> put_flash(:info, "Signed in")
            |> redirect(to: return_to)

          {:error, _reason} ->
            conn
            |> put_flash(:error, "Sign in is temporarily unavailable")
            |> put_status(:service_unavailable)
            |> render(:new,
              form: Phoenix.Component.to_form(%{"email" => email}, as: :operator)
            )
        end

      {:error, :invalid_credentials} ->
        _ =
          Audit.record(nil, :login_failed, :session, request_id(conn),
            outcome: :failed,
            metadata: %{"email_fingerprint" => fingerprint, "origin" => origin}
          )

        form = Phoenix.Component.to_form(%{"email" => email}, as: :operator)

        conn
        |> put_flash(:error, "Invalid email or password")
        |> put_status(:unprocessable_entity)
        |> render(:new, form: form)
    end
  end

  defp create_password_session(conn, _params) do
    conn
    |> put_flash(:error, "Invalid email or password")
    |> put_status(:unprocessable_entity)
    |> render(:new, form: Phoenix.Component.to_form(%{"email" => ""}, as: :operator))
  end

  defp request_id(conn), do: List.first(get_resp_header(conn, "x-request-id")) || "unknown"

  defp remote_origin(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp email_fingerprint(email) do
    email
    |> String.trim()
    |> String.downcase()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
