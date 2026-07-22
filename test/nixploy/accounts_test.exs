defmodule Nixploy.AccountsTest do
  use Nixploy.DataCase, async: true

  alias Nixploy.Accounts
  alias Nixploy.Fixtures

  test "provisions a normalized bcrypt operator credential" do
    assert {:ok, operator} =
             Accounts.provision_operator(%{
               email: "  Operator@Example.COM ",
               password: "correct horse battery staple"
             })

    assert operator.email == "operator@example.com"
    assert operator.password_hash =~ "$2"
    refute operator.password
  end

  test "authenticates valid credentials without distinguishing failures" do
    operator =
      Fixtures.operator_fixture(%{email: "operator@example.com", password: "valid password 123"})

    assert {:ok, authenticated} =
             Accounts.authenticate_operator(" OPERATOR@example.com ", "valid password 123")

    assert authenticated.id == operator.id

    assert {:error, :invalid_credentials} =
             Accounts.authenticate_operator(operator.email, "incorrect password")

    assert {:error, :invalid_credentials} =
             Accounts.authenticate_operator("missing@example.com", "incorrect password")
  end

  test "provisioning an existing email rotates its password" do
    operator =
      Fixtures.operator_fixture(%{email: "operator@example.com", password: "old password 123"})

    assert {:ok, rotated} =
             Accounts.provision_operator(%{
               email: "operator@example.com",
               password: "new password 456"
             })

    assert rotated.id == operator.id

    assert {:error, :invalid_credentials} =
             Accounts.authenticate_operator(operator.email, "old password 123")

    assert {:ok, _operator} =
             Accounts.authenticate_operator(operator.email, "new password 456")
  end
end
