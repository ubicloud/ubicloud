# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:dns_server) do
      column :id, :uuid, primary_key: true, default: nil
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :name, :text, collate: '"C"', null: false, unique: true
    end

    create_table(:dns_servers_dns_zones) do
      foreign_key :dns_zone_id, :dns_zone, type: :uuid
      foreign_key :dns_server_id, :dns_server, type: :uuid
    end

    create_table(:dns_servers_vms) do
      foreign_key :dns_server_id, :dns_server, type: :uuid
      foreign_key :vm_id, :vm, type: :uuid
    end

    create_table(:seen_dns_records_by_dns_servers) do
      foreign_key :dns_record_id, :dns_record, type: :uuid
      foreign_key :dns_server_id, :dns_server, type: :uuid
    end
  end
end
