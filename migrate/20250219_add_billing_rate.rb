# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:billing_rate) do
      column :resource_type, String, null: false
      column :resource_family, String, null: false
      column :location, String, null: false
      column :unit_price, Float, null: false
      column :billed_by, String, null: false
      column :active_from, Time, null: false
      column :id, :uuid, primary_key: true
    end
  end
end
