# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :allocation_rules, :jsonb
    end
  end
end
