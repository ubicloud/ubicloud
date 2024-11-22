# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_installation) do
      add_column :cache_enabled, :boolean, default: false, null: false
    end
  end
end
