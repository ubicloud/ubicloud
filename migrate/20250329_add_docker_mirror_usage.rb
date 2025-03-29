# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_installation) do
      add_column :use_docker_mirror, :boolean, default: false, null: false
    end
  end
end
