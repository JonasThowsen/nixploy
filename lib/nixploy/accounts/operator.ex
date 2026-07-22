defmodule Nixploy.Accounts.Operator do
  @moduledoc "A provisioned control-plane operator."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "operators" do
    field :email, :string
    field :password_hash, :string, redact: true
    field :password, :string, virtual: true, redact: true

    timestamps(type: :utc_datetime)
  end

  def provision_changeset(operator, attrs) do
    operator
    |> cast(attrs, [:email, :password])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 160)
    |> validate_length(:password, min: 12, max: 72)
    |> unique_constraint(:email)
    |> hash_password()
  end

  defp hash_password(changeset) do
    changeset = validate_length(changeset, :password, max: 72, count: :bytes)
    password = get_change(changeset, :password)

    if changeset.valid? and is_binary(password) do
      changeset
      |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end
end
