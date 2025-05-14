# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :allocator_preferences, :jsonb, null: false, default: "{}"
    end
  end
end
