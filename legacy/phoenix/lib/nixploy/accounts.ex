defmodule Nixploy.Accounts do
  @moduledoc "Provisioned operator identities for the control plane."

  alias Nixploy.Accounts.Operator
  alias Nixploy.Repo

  # TODO(tracer): Add invitation flows, explicit recovery credential rotation,
  # multiple roles, authorization policies, and operator audit records after
  # the identity-only Tailscale production path proves the boundary.
  def provision_operator(attrs) do
    attrs = Map.new(attrs)
    email = attrs[:email] || attrs["email"]

    email
    |> operator_for_email()
    |> Operator.provision_changeset(attrs)
    |> Repo.insert_or_update()
  end

  def provision_identity_operator(email) do
    email
    |> operator_for_email()
    |> Operator.identity_changeset(%{email: email})
    |> Repo.insert_or_update()
  end

  def authenticate_operator(email, password) when is_binary(email) and is_binary(password) do
    case Repo.get_by(Operator, email: normalize_email(email)) do
      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      %{password_hash: password_hash} = operator when is_binary(password_hash) ->
        if Bcrypt.verify_pass(password, password_hash),
          do: {:ok, operator},
          else: {:error, :invalid_credentials}

      _identity_only_operator ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  def authenticate_operator(_email, _password) do
    Bcrypt.no_user_verify()
    {:error, :invalid_credentials}
  end

  def get_operator(id) when is_binary(id), do: Repo.get(Operator, id)
  def get_operator(_id), do: nil

  def get_operator_by_email(email) when is_binary(email) do
    Repo.get_by(Operator, email: normalize_email(email))
  end

  def get_operator_by_email(_email), do: nil

  defp operator_for_email(email) do
    case normalize_email(email) do
      nil -> %Operator{}
      normalized -> Repo.get_by(Operator, email: normalized) || %Operator{}
    end
  end

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(_email), do: nil
end
