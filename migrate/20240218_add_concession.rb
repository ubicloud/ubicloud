# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:concession) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :project_id, :project, type: :uuid, null: false
      column :resource_type, :text, collate: '"C"'
      column :credit, :numeric, null: false, default: 0
      constraint(:min_credit) { credit >= 0 }
      column :discount, :Integer, null: false, default: 0
      constraint(:max_discount) { discount <= 100 }
    end
  end
end
