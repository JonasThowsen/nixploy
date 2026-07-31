defmodule NixployWeb.TailscaleOperatorAuthTest do
  use NixployWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Nixploy.{Audit, Fixtures}

  setup do
    previous_auth_mode = Application.fetch_env!(:nixploy, :auth_mode)
    Application.put_env(:nixploy, :auth_mode, :tailscale)

    on_exit(fn -> Application.put_env(:nixploy, :auth_mode, previous_auth_mode) end)
  end

  test "authenticates a provisioned operator from the trusted Tailscale login header", %{
    conn: conn
  } do
    operator = Fixtures.operator_fixture(email: "operator@example.com")

    conn =
      conn
      |> put_req_header("tailscale-user-login", " Operator@Example.com ")
      |> get(~p"/")

    assert html_response(conn, 200) =~ "Everything at a glance"
    assert html_response(conn, 200) =~ operator.email
    assert get_session(conn, :operator_id) == operator.id

    assert Enum.any?(Audit.list_recent_events(), fn event ->
             event.operator_id == operator.id and event.action == "login" and
               event.metadata["authentication"] == "tailscale"
           end)
  end

  test "carries the Tailscale operator into the LiveView session", %{conn: conn} do
    operator = Fixtures.operator_fixture(email: "operator@example.com")
    conn = put_req_header(conn, "tailscale-user-login", operator.email)

    assert {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Everything at a glance"
    assert html =~ operator.email
    refute html =~ "Sign out"
  end

  test "rejects a request without a Tailscale identity instead of offering password login", %{
    conn: conn
  } do
    conn = get(conn, ~p"/")

    assert response(conn, 403) == "Tailscale identity is not authorized for nixploy"
    refute get_session(conn, :operator_id)
  end

  test "rejects an unprovisioned Tailscale identity", %{conn: conn} do
    conn =
      conn
      |> put_req_header("tailscale-user-login", "unknown@example.com")
      |> get(~p"/")

    assert response(conn, 403) == "Tailscale identity is not authorized for nixploy"
  end

  test "the Tailscale identity overrides a stale password session", %{conn: conn} do
    stale_operator = Fixtures.operator_fixture(email: "stale@example.com")
    tailscale_operator = Fixtures.operator_fixture(email: "tailscale@example.com")

    conn =
      conn
      |> log_in_operator(stale_operator)
      |> put_req_header("tailscale-user-login", tailscale_operator.email)
      |> get(~p"/")

    assert html_response(conn, 200) =~ tailscale_operator.email
    refute html_response(conn, 200) =~ stale_operator.email
    assert get_session(conn, :operator_id) == tailscale_operator.id
  end

  test "disables the password login endpoint", %{conn: conn} do
    operator = Fixtures.operator_fixture(email: "operator@example.com")

    conn =
      post(conn, ~p"/login", %{
        "operator" => %{"email" => operator.email, "password" => "correct horse battery staple"}
      })

    assert response(conn, 403) ==
             "Password login is disabled when Tailscale authentication is enabled"
  end

  test "keeps health checks independent of operator authentication", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/health") |> json_response(200)
  end
end
