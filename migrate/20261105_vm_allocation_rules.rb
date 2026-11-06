# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      # NULL means "not written yet"; an empty object means no rules.
      add_column :allocation_rules, :jsonb, null: true
    end
  end
end
