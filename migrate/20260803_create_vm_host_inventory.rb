# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_host_inventory) do
      foreign_key :id, :vm_host, type: :uuid, primary_key: true, on_delete: :cascade
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :server_model, :text, collate: '"C"'
      column :cpu, :text, collate: '"C"'
      column :memory, :text, collate: '"C"'
      column :storage, :text, collate: '"C"'
      column :uplink, :text, collate: '"C"'
      column :gpu, :text, collate: '"C"'
      column :monthly_price, :numeric
      column :currency, :text, collate: '"C"'

      constraint(:allowed_currency, currency: %w[EUR USD])
      constraint(:monthly_price_not_negative) { monthly_price >= 0 }
      constraint(:currency_with_price, Sequel.lit("(monthly_price IS NULL) = (currency IS NULL)"))
    end
  end
end
