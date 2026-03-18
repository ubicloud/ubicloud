# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:billing_record) do
      add_column :tags, :jsonb, null: false, default: "[]"
      add_column :resource_type, :text, collate: '"C"', null: false, default: ""
    end
  end
end
