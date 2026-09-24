# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:accounts) do
      add_column :project_limit, Integer, null: false, default: 10
      add_constraint(:project_limit_positive) { project_limit > 0 }
    end
  end
end
