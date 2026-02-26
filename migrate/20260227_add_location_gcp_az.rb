# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:location_gcp_az) do
      column :id, :uuid, primary_key: true
      foreign_key :location_id, :location, type: :uuid, null: false, on_delete: :cascade
      column :az, :text, null: false
      column :zone_name, :text, null: false
      index [:location_id, :az], unique: true
    end
  end
end
