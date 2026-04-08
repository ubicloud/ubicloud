# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_log_destination) do
      # UBID.to_base32_n("1d") => 45
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 45)
      foreign_key :postgres_resource_id, :postgres_resource, type: :uuid, null: false
      column :name, :text, null: false
      column :type, :text, null: false
      column :url, :text, null: false
      column :options, :text
      constraint(:valid_type, type: %w[otlp syslog])
    end
  end
end
