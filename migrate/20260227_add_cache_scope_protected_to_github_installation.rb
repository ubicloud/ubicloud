# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_installation) do
      add_column :cache_scope_protected, :boolean, default: true, null: false
    end
  end
end
