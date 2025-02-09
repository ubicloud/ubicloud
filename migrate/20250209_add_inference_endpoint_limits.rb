# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:inference_endpoint) do
      add_column :max_requests, :integer, null: false, default: 500
      add_column :max_project_rps, :integer, null: false, default: 100
      add_column :max_project_tps, :integer, null: false, default: 10000
    end
  end
end
