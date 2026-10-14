# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:scheduler_metric_counter) do
      column :name, :text, primary_key: true
      column :value, :bigint, null: false, default: 0
    end
  end
end
