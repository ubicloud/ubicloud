# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_repository) do
      add_column :extra_cache_storage_gib, :integer
      add_constraint(:github_repository_extra_cache_storage_gib_positive) { extra_cache_storage_gib > 0 }
    end
  end
end
