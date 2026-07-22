defmodule NixployWeb.HealthControllerTest do
  use NixployWeb.ConnCase, async: true

  test "exposes unauthenticated liveness", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "reports database readiness", %{conn: conn} do
    conn = get(conn, ~p"/ready")
    assert json_response(conn, 200) == %{"status" => "ready"}
  end
end
