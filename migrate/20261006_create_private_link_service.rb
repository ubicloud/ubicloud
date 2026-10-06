# frozen_string_literal: true

# add_unique_constraint has no automatic reverse in Sequel, so up and down
# are spelled out.
Sequel.migration do
  up do
    # Lets a child table reference a subnet together with its project and
    # location, so the database guarantees the three agree (see
    # private_link_service below).
    alter_table(:private_subnet) do
      add_unique_constraint [:id, :project_id, :location_id], name: :private_subnet_id_project_id_location_id_key
    end

    # project_id and location_id are pinned to the subnet's by the composite
    # foreign key; the name is unique per project and location, as the URL is.
    create_table(:private_link_service) do
      # "pn": Crockford base32 has no "l", so "pl" is not a valid ubid prefix.
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
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :private_link_service_id, :private_link_service, type: :uuid, null: false, on_delete: :cascade
      column :port, :integer, null: false
      column :target_port, :integer, null: false

      unique [:private_link_service_id, :port]
      constraint(:private_link_service_port_range, Sequel.lit("port BETWEEN 1 AND 65535 AND target_port BETWEEN 1 AND 65535"))
    end
  end

  down do
    drop_table(:private_link_service_port)
    drop_table(:private_link_service)
    alter_table(:private_subnet) do
      drop_constraint :private_subnet_id_project_id_location_id_key
    end
  end
end
