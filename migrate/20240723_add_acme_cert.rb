# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:cert) do
      column :id, :uuid, primary_key: true
      column :hostname, :text, collate: '"C"', null: false
      foreign_key :dns_zone_id, :dns_zone, type: :uuid, null: false
      column :created_at, :timestamp, null: false, default: Sequel.function(:now)
      column :cert, :text, collate: '"C"'
      column :account_key, :text, collate: '"C"'
      column :kid, :text, collate: '"C"'
      column :order_url, :text, collate: '"C"'
      column :csr_key, :text, collate: '"C"'
    end
  end
end
