# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:host_provider) do
      foreign_key :id, :vm_host, type: :uuid
      column :server_identifier, :text, null: false
      column :provider_name, :text, null: false
      primary_key [:provider_name, :server_identifier]
    end

    run <<-SQL
      INSERT INTO host_provider (id, server_identifier, provider_name) SELECT id, server_identifier, 'hetzner' FROM hetzner_host;
    SQL
  end

  down do
    drop_table :host_provider
  end
end
