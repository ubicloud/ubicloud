# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_installation) do
      add_column :github_created_at, Time
    end
  end
end
