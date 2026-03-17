# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_repository) do
      add_column :no_cache_since, :timestamptz
    end
  end
end
