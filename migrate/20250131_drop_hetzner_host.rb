# frozen_string_literal: true

Sequel.migration do
  up do
    drop_table :hetzner_host
  end

  down do
    create_table :hetzner_host do
      foreign_key :id, :vm_host, type: :uuid
      column :server_identifier, :text, null: false
      primary_key [:server_identifier]
    end

    run <<-SQL
      INSERT INTO hetzner_host (id, server_identifier) SELECT id, server_identifier FROM host_provider WHERE provider_name = 'hetzner';
    SQL
  end
end
