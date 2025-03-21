# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_runner) do
      add_column :allocated_at, :timestamptz
    end
  end
end
