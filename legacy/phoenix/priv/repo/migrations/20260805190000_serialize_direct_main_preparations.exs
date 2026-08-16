defmodule Nixploy.Repo.Migrations.SerializeDirectMainPreparations do
  use Ecto.Migration

  def change do
    create unique_index(
             :deployment_inputs,
             [:application_key, :selected_target],
             where: "input_kind = 'git_main' AND state = 'staging'",
             name: :one_active_main_preparation_per_application_target
           )
  end
end
