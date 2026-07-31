defmodule NixployWeb.OperatorSessionControllerTest do
  use NixployWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nixploy.Fixtures

  test "redirects unauthenticated dashboard requests to login", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/login"
    assert get_session(conn, :operator_return_to) == ~p"/"
  end

  test "renders the operator login", %{conn: conn} do
    conn = get(conn, ~p"/login")

    assert html_response(conn, 200) =~ "Restricted control plane"
    assert html_response(conn, 200) =~ "operator-login-form"
  end

  test "rejects invalid credentials with a generic error", %{conn: conn} do
    conn =
      post(conn, ~p"/login", %{
        "operator" => %{"email" => "missing@example.com", "password" => "incorrect password"}
      })

    assert html_response(conn, 422) =~ "Invalid email or password"
    refute html_response(conn, 422) =~ "missing operator"
  end

  test "renews the session and grants dashboard access", %{conn: conn} do
    operator =
      Fixtures.operator_fixture(%{
        email: "operator@example.com",
        password: "correct horse battery staple"
      })

    conn =
      post(conn, ~p"/login", %{
        "operator" => %{
          "email" => operator.email,
          "password" => "correct horse battery staple"
        }
      })

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :operator_id) == operator.id

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Current runtime state"
    assert html_response(conn, 200) =~ operator.email
  end

  test "LiveView rejects a missing operator session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  test "signs the operator out", %{conn: conn} do
    operator = Fixtures.operator_fixture()
    conn = conn |> log_in_operator(operator) |> delete(~p"/logout")

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :operator_id)
  end
end
