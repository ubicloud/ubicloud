# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:usage_alert) do
      add_column :resource_type, :text, collate: '"C"'
      add_column :hard_limit, :bool, null: false, default: false
    end
  end
end
