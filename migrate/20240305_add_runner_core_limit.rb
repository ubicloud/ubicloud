# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project) do
      add_column :runner_core_limit, Integer, null: false, default: 300
    end
  end
end
