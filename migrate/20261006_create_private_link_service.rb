# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:private_link_service) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(725)") # UBID.to_base32_n("pn") => 725
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      column :private_subnet_id, :uuid, null: false
      foreign_key [:private_subnet_id, :project_id, :location_id], :private_subnet, key: [:id, :project_id, :location_id], name: :private_link_service_private_subnet_fkey
      foreign_key :postgres_resource_id, :postgres_resource, type: :uuid, on_delete: :set_null
      column :name, :text, collate: '"C"', null: false
      column :allowed_principals, "text[]", collate: '"C"', null: false, default: Sequel.lit("'{}'::text[]")
      column :private_dns_name, :text, collate: '"C"'
      column :ip_address_type, :text, collate: '"C"', null: false, default: "ipv4"

      unique [:project_id, :location_id, :name]
      index :postgres_resource_id
      constraint(:private_link_service_ip_address_type_check, ip_address_type: %w[ipv4 ipv6 dual])
    end

    create_table(:private_link_service_port) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 474) # UBID.to_base32_n("et") => 474
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :private_link_service_id, :private_link_service, type: :uuid, null: false, on_delete: :cascade
      column :port, :integer, null: false
      column :target_port, :integer, null: false

      unique [:private_link_service_id, :port]
      constraint(:private_link_service_port_range, Sequel.lit("port BETWEEN 1 AND 65535 AND target_port BETWEEN 1 AND 65535"))
    end
  end
end
