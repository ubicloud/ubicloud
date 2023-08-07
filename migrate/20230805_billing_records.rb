# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:billing_record) do
      column :id, :uuid, primary_key: true, default: nil
      column :project_id, :project, type: :uuid, null: false
      column :resource_id, :uuid, null: false
      column :resource_name, :text, collate: '"C"', null: false
      column :span, :tstzrange, null: false, default: Sequel.lit("tstzrange(now(), NULL, '[)')")
      foreign_key :billing_rate_id, :billing_rate, type: :uuid, null: false
      column :amount, :numeric, null: false
      index :project_id
      index :resource_id, unique: true, where: Sequel.lit("upper(span) = NULL")
      index :span, type: :gist
      exclude [[:resource_id, "="], [:span, "&&"]]
    end
  end
end
