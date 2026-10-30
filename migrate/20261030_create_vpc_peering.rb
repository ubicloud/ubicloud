# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vpc_peering) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 733) # UBID.to_base32_n("px") => 733
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: false
      column :peer_account_id, :text, collate: '"C"', null: false
      column :peer_vpc_id, :text, collate: '"C"', null: false
      column :state, :text, collate: '"C"', null: false, default: "creating"
      column :state_message, :text
      column :peer_cidrs, "cidr[]", null: false, default: Sequel.pg_array([], :cidr)
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      unique [:private_subnet_id, :peer_vpc_id]
      constraint(:vpc_peering_state_check, state: %w[creating waiting_for_peer configuring active failed])
      constraint(:vpc_peering_failed_message_check, Sequel.lit("state <> 'failed' OR state_message IS NOT NULL"))
    end

    create_table(:vpc_peering_aws_resource) do
      foreign_key :id, :vpc_peering, type: :uuid, primary_key: true, on_delete: :cascade
      column :peer_region, :text, collate: '"C"', null: false
      column :peering_connection_id, :text, collate: '"C"', unique: true
      column :requester_account_id, :text, collate: '"C"'
      column :expires_at, :timestamptz
      constraint(:vpc_peering_aws_resource_connection_recorded_check, Sequel.lit("(peering_connection_id IS NULL) = (requester_account_id IS NULL)"))
    end
  end
end
