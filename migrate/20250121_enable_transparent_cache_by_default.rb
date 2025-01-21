# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_installation) do
      set_column_default(:cache_enabled, true)
    end
  end
end
