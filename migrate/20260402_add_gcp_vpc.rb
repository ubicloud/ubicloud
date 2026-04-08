# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:gcp_vpc) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 539) # UBID.to_base32_n("gv") => 539
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      column :name, :text, null: false
      column :firewall_policy_name, :text
      column :network_self_link, :text
      unique [:project_id, :location_id]
    end

    create_table(:private_subnet_gcp_vpc) do
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, primary_key: true, on_delete: :cascade
      foreign_key :gcp_vpc_id, :gcp_vpc, type: :uuid, null: false
      index :gcp_vpc_id
    end
  end

  down do
    drop_table(:private_subnet_gcp_vpc)
    drop_table(:gcp_vpc)
  end
end
