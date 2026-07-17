defmodule NixployWeb.PageController do
  use NixployWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
