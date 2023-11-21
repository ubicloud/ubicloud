# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:subnet_peer) do
      column :id, :uuid, primary_key: true, default: nil
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :provider_subnet_id, :private_subnet, type: :uuid
      foreign_key :peer_subnet_id, :private_subnet, type: :uuid
    end

    alter_table(:firewall_rule) do
      add_foreign_key :subnet_peer_id, :subnet_peer, type: :uuid, null: true, default: nil
    end
  end
end
