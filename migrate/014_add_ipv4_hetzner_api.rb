# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :hetzner_host do
      foreign_key :id, :vm_host, primary_key: true, type: :uuid
      column :server_identifier, :text, null: false, unique: true
    end
  end
end
