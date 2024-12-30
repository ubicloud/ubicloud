# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:inference_endpoint) do
      add_column :tags, :jsonb, null: false, default: "{}"
    end
  end
end
