# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:deleted_record) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :deleted_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :model_name, :text, null: false
      column :model_values, :jsonb, null: false, default: "{}"
    end
  end
end
