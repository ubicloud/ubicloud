# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:inference_endpoint) do
      add_column :gpu_count, :int, default: 1, null: false
    end
  end
end
