# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:usage_alert) do
      add_column :cutoff, :bool, default: false, null: false
    end
  end
end
