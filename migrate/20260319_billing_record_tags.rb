# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:billing_record) do
      add_column :resource_tags, :jsonb, null: false, default: "[]"
    end
  end
end
